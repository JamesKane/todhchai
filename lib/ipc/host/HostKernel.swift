// SPDX-License-Identifier: BSD-3-Clause

// The hosted stand-in for croi's handle, channel, event and wait calls, on
// Linux, in one process. Semantics follow Zircon's (studied, not copied):
// handles move through channels, a write consumes its handles even when it
// fails, and waits take absolute deadlines on the monotonic clock. The
// native transport replaces this with croi's system calls (M3); code above
// it doesn't change.

import Glibc

/// A kernel object. `refs` counts the handles to it plus the queued
/// messages that carry it; when it reaches zero the object is gone.
class KernelObject {
  var signals: UInt32 = 0
  var refs = 0

  /// Called under the kernel lock when the last reference goes.
  func lastReferenceGone(_ kernel: HostKernel) {}
}

final class EventObject: KernelObject {}

/// One end of a channel. Messages written to it land in its peer's queue.
final class ChannelEnd: KernelObject {
  struct Message {
    var bytes: [UInt8]
    var handles: [(object: KernelObject, rights: Rights)]
  }

  weak var peer: ChannelEnd?
  var queue: [Message] = []

  override func lastReferenceGone(_ kernel: HostKernel) {
    if let peer {
      peer.signals |= Signals.peerClosed
      peer.peer = nil
    }
    peer = nil
    let dropped = queue
    queue = []
    for message in dropped {
      for carried in message.handles { kernel.release(carried.object) }
    }
  }
}

/// The process's kernel: one handle table, one lock, one condition that
/// every signal change broadcasts.
public final class HostKernel: @unchecked Sendable {
  public static let shared = HostKernel()

  struct Slot {
    var object: KernelObject?
    var rights: Rights = []
    var generation: UInt32 = 0
  }

  // A handle is (generation << indexBits) | (index + 1), so 0 is never valid.
  static let indexBits: UInt32 = 20
  static let indexMask: UInt32 = (1 << indexBits) - 1

  var slots: [Slot] = []
  var free: [Int] = []
  let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  let changed = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

  init() {
    pthread_mutex_init(lock, nil)
    var attr = pthread_condattr_t()
    pthread_condattr_init(&attr)
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)
    pthread_cond_init(changed, &attr)
    pthread_condattr_destroy(&attr)
  }

  /// Nanoseconds on the monotonic clock, the time base of every deadline.
  public static func now() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }

  func locked<R>(_ body: () throws(Status) -> R) throws(Status) -> R {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    return try body()
  }

  // MARK: Handles (call with the lock held)

  func install(_ object: KernelObject, _ rights: Rights) throws(Status) -> UInt32 {
    let index: Int
    if let reused = free.popLast() {
      index = reused
    } else {
      guard slots.count < Int(Self.indexMask) else { throw .outOfRange }
      index = slots.count
      slots.append(Slot())
    }
    slots[index].object = object
    slots[index].rights = rights
    return (slots[index].generation << Self.indexBits) | UInt32(index + 1)
  }

  func slotIndex(_ handle: UInt32) -> Int? {
    let index = Int(handle & Self.indexMask) - 1
    guard index >= 0, index < slots.count, slots[index].object != nil,
      slots[index].generation == handle >> Self.indexBits
    else { return nil }
    return index
  }

  func lookup(_ handle: UInt32, _ needed: Rights) throws(Status) -> KernelObject {
    guard let index = slotIndex(handle) else { throw .badHandle }
    guard slots[index].rights.isSuperset(of: needed) else { throw .accessDenied }
    return slots[index].object!
  }

  /// Empties a slot, keeping its object's reference for the caller.
  func remove(_ index: Int) -> (KernelObject, Rights) {
    let taken = (slots[index].object!, slots[index].rights)
    slots[index].object = nil
    slots[index].generation = (slots[index].generation + 1) & (UInt32.max >> Self.indexBits)
    free.append(index)
    pthread_cond_broadcast(changed)  // a waiter on this handle is cancelled
    return taken
  }

  func release(_ object: KernelObject) {
    object.refs -= 1
    if object.refs == 0 { object.lastReferenceGone(self) }
  }

  // MARK: Calls

  public func close(_ handle: UInt32) throws(Status) {
    try locked { () throws(Status) in
      guard let index = slotIndex(handle) else { throw .badHandle }
      let (object, _) = remove(index)
      release(object)
      pthread_cond_broadcast(changed)
    }
  }

  public func channelCreate() throws(Status) -> (UInt32, UInt32) {
    try locked { () throws(Status) in
      let a = ChannelEnd(), b = ChannelEnd()
      a.peer = b
      b.peer = a
      a.refs = 1
      b.refs = 1
      let ha = try install(a, .channelDefault)
      let hb = try install(b, .channelDefault)
      return (ha, hb)
    }
  }

  public func eventCreate() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let e = EventObject()
      e.refs = 1
      return try install(e, .eventDefault)
    }
  }

  /// Writes a message. The handles in `handles` are consumed whatever the
  /// outcome, as in Zircon: on failure they are closed.
  public func channelWrite(_ handle: UInt32, bytes: [UInt8], handles: [UInt32]) throws(Status) {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    var failure: Status? = nil
    var end: ChannelEnd? = nil
    do {
      end = try lookup(handle, .write) as? ChannelEnd
      if end == nil { failure = .wrongType }
    } catch {
      failure = error
    }
    // Every transferred handle leaves the table, so a failure closes them all.
    var carried: [(object: KernelObject, rights: Rights)] = []
    for h in handles {
      guard let index = slotIndex(h) else {
        failure = failure ?? .badHandle
        continue
      }
      if !slots[index].rights.contains(.transfer) { failure = failure ?? .accessDenied }
      if let end, slots[index].object === end || slots[index].object === end.peer {
        failure = failure ?? .notSupported
      }
      carried.append(remove(index))
    }
    if bytes.count > 65_536 || handles.count > 64 { failure = failure ?? .outOfRange }
    if failure == nil, end?.peer == nil { failure = .peerClosed }
    if let failure {
      for c in carried { release(c.object) }
      throw failure
    }
    let peer = end!.peer!
    peer.queue.append(.init(bytes: bytes, handles: carried))
    peer.signals |= Signals.readable
    pthread_cond_broadcast(changed)
  }

  /// A message's sizes.
  public struct ReadResult: Equatable, Sendable {
    public var byteCount: Int
    public var handleCount: Int
  }

  /// Reads the next message into the buffers, installing its handles. If the
  /// buffers are too small, the message stays queued and the error says
  /// what it needs.
  public func channelRead(
    _ handle: UInt32, bytes: UnsafeMutableRawBufferPointer, handles: UnsafeMutableBufferPointer<UInt32>
  ) throws(ReadError) -> ReadResult {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    func fail(_ status: Status, _ needed: ReadResult = ReadResult(byteCount: 0, handleCount: 0)) -> ReadError {
      ReadError(status: status, needed: needed)
    }
    let object: KernelObject
    do {
      object = try lookup(handle, .read)
    } catch {
      throw fail(error)
    }
    guard let end = object as? ChannelEnd else { throw fail(.wrongType) }
    guard let message = end.queue.first else { throw fail(end.peer == nil ? .peerClosed : .shouldWait) }
    let needed = ReadResult(byteCount: message.bytes.count, handleCount: message.handles.count)
    guard message.bytes.count <= bytes.count, message.handles.count <= handles.count else {
      throw fail(.bufferTooSmall, needed)
    }
    // Install first: if the table is full, the message stays queued.
    var installed: [UInt32] = []
    for carried in message.handles {
      do {
        installed.append(try install(carried.object, carried.rights))
      } catch {
        for h in installed { _ = remove(slotIndex(h)!) }
        throw fail(error)
      }
    }
    end.queue.removeFirst()
    if end.queue.isEmpty { end.signals &= ~Signals.readable }
    message.bytes.withUnsafeBytes { bytes.copyMemory(from: $0) }
    for (i, h) in installed.enumerated() { handles[i] = h }
    return needed
  }

  /// A failed read; `needed` is set when the status is `bufferTooSmall`.
  public struct ReadError: Error {
    public var status: Status
    public var needed: ReadResult
  }

  /// Sets and clears an object's settable signals.
  public func signal(_ handle: UInt32, clear: UInt32, set: UInt32) throws(Status) {
    try locked { () throws(Status) in
      guard (clear | set) & ~Signals.settable == 0 else { throw .invalidArgs }
      let object = try lookup(handle, .signal)
      object.signals = (object.signals & ~clear) | set
      pthread_cond_broadcast(changed)
    }
  }

  /// Waits until the object asserts one of `signals` or `deadline` passes.
  /// Returns the signals observed; throws `timedOut` at the deadline, or
  /// `canceled` if the handle is closed meanwhile.
  public func wait(_ handle: UInt32, for signals: UInt32, deadline: Int64) throws(WaitError) -> UInt32 {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    let object: KernelObject
    do {
      object = try lookup(handle, .wait)
    } catch {
      throw WaitError(status: error, observed: 0)
    }
    while true {
      guard slotIndex(handle).map({ slots[$0].object === object }) == true else {
        throw WaitError(status: .canceled, observed: object.signals)
      }
      if object.signals & signals != 0 { return object.signals }
      if deadline != infiniteDeadline && Self.now() >= deadline {
        throw WaitError(status: .timedOut, observed: object.signals)
      }
      if deadline == infiniteDeadline {
        pthread_cond_wait(changed, lock)
      } else {
        var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
        pthread_cond_timedwait(changed, lock, &ts)
      }
    }
  }

  /// A failed wait, with the signals observed when it ended.
  public struct WaitError: Error {
    public var status: Status
    public var observed: UInt32
  }
}
