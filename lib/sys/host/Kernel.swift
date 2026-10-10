// SPDX-License-Identifier: BSD-3-Clause

// The hosted kernel: croi's object model (Zircon's semantics and values,
// studied, not copied) on Linux, in one process. Hosted processes are
// threads with handle tables of their own, so a process can use only the
// handles it was given; memory isn't isolated (docs/milestones/N0.md).
// `Sys` (lib/sys/api) is the typed face services use; at M3 it calls croi
// instead, and nothing above it changes.
//
// One lock guards everything, and one condition is broadcast on every
// change: simple, and enough for a development kernel.

import Glibc
import Synchronization
import SysABI

// MARK: Objects

/// A wait_async registration: when the object asserts one of `signals`,
/// a packet goes to `port`, once.
struct AsyncWait {
  var port: PortObject
  var key: UInt64
  var signals: UInt32
  var edge: Bool
  /// The handle it was made through: closing that handle cancels it.
  var process: ObjectIdentifier
  var handle: UInt32
}

class KernelObject {
  let koid: UInt64
  let type: UInt32
  var signals: UInt32 = 0
  var refs = 0
  var asyncWaits: [AsyncWait] = []

  init(_ kernel: HostKernel, type: UInt32) {
    kernel.lastKoid += 1
    koid = kernel.lastKoid
    self.type = type
  }

  /// The koid of the object this one is paired with (a channel's or
  /// eventpair's peer), for object_get_info.
  var relatedKoid: UInt64 { 0 }
  /// Signals object_signal may change.
  var settable: UInt32 { Signals.user }

  /// Under the lock, when the last handle (or carrying message) goes.
  func lastReferenceGone(_ kernel: HostKernel) {}
}

final class EventObject: KernelObject {
  override var settable: UInt32 { Signals.signaled | Signals.user }
}

class Peered: KernelObject {
  weak var peer: Peered?
  var peerKoid: UInt64 = 0
  override var relatedKoid: UInt64 { peerKoid }

  override func lastReferenceGone(_ kernel: HostKernel) {
    if let peer {
      kernel.update(peer, set: Signals.peerClosed)
      peer.peer = nil
    }
    peer = nil
  }
}

final class EventPairEnd: Peered {
  override var settable: UInt32 { Signals.signaled | Signals.user }
}

final class ChannelEnd: Peered {
  struct Message {
    var bytes: [UInt8]
    var handles: [(object: KernelObject, rights: Rights)]
  }

  var queue: [Message] = []
  /// Calls waiting on this end for their reply, by txid; nil until it comes.
  var calls: [UInt32: Message?] = [:]

  override func lastReferenceGone(_ kernel: HostKernel) {
    super.lastReferenceGone(kernel)
    let dropped = queue + calls.values.compactMap { $0 }
    queue = []
    calls = [:]
    for message in dropped {
      for carried in message.handles { kernel.release(carried.object) }
    }
  }
}

final class PortObject: KernelObject {
  var packets: [Packet] = []
}

final class VMOObject: KernelObject {
  let base: UnsafeMutableRawPointer
  let size: Int

  init(_ kernel: HostKernel, size: Int) {
    self.size = size
    base = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 4096)
    base.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
    super.init(kernel, type: ObjectType.vmo)
  }

  deinit { base.deallocate() }
}

final class TimerObject: KernelObject {
  var deadline: Int64? = nil
}

class TaskObject: KernelObject {
  var killed = false
}

final class JobObject: TaskObject {
  weak var parent: JobObject?
  var children: [JobObject] = []
  var processes: [ProcessObject] = []
}

final class ProcessObject: TaskObject {
  let name: String
  weak var job: JobObject?
  var table = HandleTable()
  /// Threads running, and whether one ever started.
  var running = 0
  var started = false
  var returnCode: Int64 = 0

  init(_ kernel: HostKernel, name: String, job: JobObject?) {
    self.name = name
    self.job = job
    super.init(kernel, type: ObjectType.process)
  }
}

final class ThreadObject: TaskObject {
  let process: ProcessObject
  var started = false

  init(_ kernel: HostKernel, process: ProcessObject) {
    self.process = process
    super.init(kernel, type: ObjectType.thread)
  }

  override func lastReferenceGone(_ kernel: HostKernel) { kernel.release(process) }
}

/// A process's handles. A handle is (generation << 20) | (index + 1), so 0
/// is never valid and a closed handle's number fails until reused.
struct HandleTable {
  struct Slot {
    var object: KernelObject?
    var rights: Rights = []
    var generation: UInt32 = 0
  }

  static let indexBits: UInt32 = 20
  static let indexMask: UInt32 = (1 << indexBits) - 1

  var slots: [Slot] = []
  var free: [Int] = []

  mutating func install(_ object: KernelObject, _ rights: Rights) throws(Status) -> UInt32 {
    let index: Int
    if let reused = free.popLast() {
      index = reused
    } else {
      guard slots.count < Int(Self.indexMask) else { throw .noResources }
      index = slots.count
      slots.append(Slot())
    }
    slots[index].object = object
    slots[index].rights = rights
    return (slots[index].generation << Self.indexBits) | UInt32(index + 1)
  }

  func index(_ handle: UInt32) -> Int? {
    let i = Int(handle & Self.indexMask) - 1
    guard i >= 0, i < slots.count, slots[i].object != nil, slots[i].generation == handle >> Self.indexBits else {
      return nil
    }
    return i
  }

  mutating func remove(_ i: Int) -> (KernelObject, Rights) {
    let taken = (slots[i].object!, slots[i].rights)
    slots[i].object = nil
    slots[i].generation = (slots[i].generation + 1) & (UInt32.max >> Self.indexBits)
    free.append(i)
    return taken
  }
}

// MARK: The kernel

public final class HostKernel: @unchecked Sendable {
  public static let shared = HostKernel()

  var lastKoid: UInt64 = 1023
  let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  let changed = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
  /// The calling thread's process.
  var currentKey = pthread_key_t()
  /// The process a thread belongs to when the kernel didn't start it (the
  /// host's own threads: tests, tools, the hosted boot's first thread).
  var hostProcess: ProcessObject!
  var rootJob: JobObject!
  var timers: [TimerObject] = []
  var timerThreadStarted = false
  var futexWaiters: [FutexWaiter] = []
  var lastTxid: UInt32 = 0
  /// Ends a started thread's accounting when it exits, however it does
  /// (pthread_exit in a kernel call doesn't unwind Swift frames).
  var endKey = pthread_key_t()

  init() {
    pthread_mutex_init(lock, nil)
    var attr = pthread_condattr_t()
    pthread_condattr_init(&attr)
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)
    pthread_cond_init(changed, &attr)
    pthread_condattr_destroy(&attr)
    pthread_key_create(&currentKey, nil)
    pthread_key_create(&endKey) { arg in
      let s = Unmanaged<HostKernel.Start>.fromOpaque(arg!).takeRetainedValue()
      s.kernel.threadEnded(s.thread)
    }
    rootJob = JobObject(self, type: ObjectType.job)
    rootJob.refs = 1  // the kernel's own reference
    hostProcess = ProcessObject(self, name: "host", job: rootJob)
    hostProcess.refs = 1
    hostProcess.started = true
    rootJob.processes.append(hostProcess)
  }

  /// Nanoseconds on the monotonic clock, the time base of every deadline.
  public static func now() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }

  public static let infinite = Int64.max

  // MARK: Locking, the caller's process, kills

  /// The calling thread, if the kernel started it.
  var currentThread: ThreadObject? {
    guard let t = pthread_getspecific(currentKey) else { return nil }
    return Unmanaged<ThreadObject>.fromOpaque(t).takeUnretainedValue()
  }

  var current: ProcessObject { currentThread?.process ?? hostProcess }

  /// Runs `body` under the lock. A thread whose process was killed never
  /// returns from a kernel call: it exits here, as croi's do.
  func locked<R>(_ body: () throws(Status) -> R) throws(Status) -> R {
    pthread_mutex_lock(lock)
    exitIfKilled()
    defer { pthread_mutex_unlock(lock) }
    return try body()
  }

  /// Under the lock: ends the calling thread if it or its process was killed.
  func exitIfKilled() {
    guard let t = currentThread, t.killed || t.process.killed else { return }
    pthread_mutex_unlock(lock)
    pthread_exit(nil)
  }

  /// Waits for any change, until `deadline`; false if it passed.
  func awaitChange(until deadline: Int64) -> Bool {
    if deadline == Self.infinite {
      pthread_cond_wait(changed, lock)
    } else {
      if Self.now() >= deadline { return false }
      var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
      pthread_cond_timedwait(changed, lock, &ts)
    }
    exitIfKilled()
    return true
  }

  // MARK: Handles (under the lock)

  func install(_ object: KernelObject, _ rights: Rights, in process: ProcessObject? = nil) throws(Status) -> UInt32 {
    try (process ?? current).table.install(object, rights)
  }

  func lookup(_ handle: UInt32, _ needed: Rights) throws(Status) -> KernelObject {
    let p = current
    guard let i = p.table.index(handle) else { throw .badHandle }
    guard p.table.slots[i].rights.isSuperset(of: needed) else { throw .accessDenied }
    return p.table.slots[i].object!
  }

  /// Zircon's order of errors, as croi's: bad handle, wrong type, access denied.
  func lookup<T: KernelObject>(_ handle: UInt32, _ needed: Rights, as: T.Type) throws(Status) -> T {
    guard let o = try lookup(handle, []) as? T else { throw .wrongType }
    _ = try lookup(handle, needed)
    return o
  }

  func release(_ object: KernelObject) {
    object.refs -= 1
    if object.refs == 0 { object.lastReferenceGone(self) }
  }

  /// Takes a handle out of the caller's table: its wait_asyncs are
  /// cancelled, and the caller now holds its reference.
  func take(_ handle: UInt32) throws(Status) -> (KernelObject, Rights) {
    let p = current
    guard let i = p.table.index(handle) else { throw .badHandle }
    let taken = p.table.remove(i)
    let id = ObjectIdentifier(p)
    taken.0.asyncWaits.removeAll { $0.process == id && $0.handle == handle }
    pthread_cond_broadcast(changed)  // a wait on this handle is cancelled
    return taken
  }

  /// Sets and clears an object's signals; wakes waiters and fires the
  /// wait_asyncs they meet.
  func update(_ o: KernelObject, set: UInt32 = 0, clear: UInt32 = 0) {
    let before = o.signals
    o.signals = (o.signals & ~clear) | set
    if o.signals != before {
      var keep: [AsyncWait] = []
      for w in o.asyncWaits {
        let met = o.signals & w.signals
        if met != 0 && (!w.edge || before & w.signals == 0) {
          w.port.packets.append(Packet(key: w.key, type: 1, status: 0,
                                       payload: (UInt64(met) | UInt64(o.signals) << 32, 1, UInt64(Self.now()), 0)))
        } else {
          keep.append(w)
        }
      }
      o.asyncWaits = keep
      pthread_cond_broadcast(changed)
    }
  }

  // MARK: Handle calls

  public func close(_ handle: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let (object, _) = try take(handle)
      release(object)
    }
  }

  public func duplicate(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let have = p.table.slots[i].rights
      guard have.contains(.duplicate) else { throw .accessDenied }
      let object = p.table.slots[i].object!
      let r = rights == .sameRights ? have : rights
      guard have.isSuperset(of: r) else { throw .invalidArgs }
      object.refs += 1
      return try install(object, r)
    }
  }

  public func replace(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let have = p.table.slots[i].rights
      let r = rights == .sameRights ? have : rights
      let (object, _) = try take(handle)
      guard have.isSuperset(of: r) else {
        release(object)
        throw .invalidArgs
      }
      return try install(object, r)
    }
  }

  public struct HandleInfo: Equatable, Sendable {
    public var koid: UInt64
    public var rights: Rights
    public var type: UInt32
    public var relatedKoid: UInt64
  }

  /// object_get_info, topic HANDLE_BASIC.
  public func info(_ handle: UInt32) throws(Status) -> HandleInfo {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let o = p.table.slots[i].object!
      return HandleInfo(koid: o.koid, rights: p.table.slots[i].rights, type: o.type, relatedKoid: o.relatedKoid)
    }
  }

  // MARK: Signals and waiting

  public func signal(_ handle: UInt32, clear: UInt32, set: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let o = try lookup(handle, .signal)
      guard (clear | set) & ~o.settable == 0 else { throw .invalidArgs }
      update(o, set: set, clear: clear)
    }
  }

  public func signalPeer(_ handle: UInt32, clear: UInt32, set: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let o = try lookup(handle, .signalPeer, as: Peered.self)
      guard (clear | set) & ~o.settable == 0 else { throw .invalidArgs }
      guard let peer = o.peer else { throw .peerClosed }
      update(peer, set: set, clear: clear)
    }
  }

  /// A failed wait, with the signals observed when it ended.
  public struct WaitError: Error {
    public var status: Status
    public var observed: UInt32
  }

  /// Waits until the object asserts one of `signals` or `deadline` passes.
  public func wait(_ handle: UInt32, for signals: UInt32, deadline: Int64) throws(WaitError) -> UInt32 {
    pthread_mutex_lock(lock)
    exitIfKilled()
    defer { pthread_mutex_unlock(lock) }
    let object: KernelObject
    do {
      object = try lookup(handle, .wait)
    } catch {
      throw WaitError(status: error, observed: 0)
    }
    while true {
      guard let i = current.table.index(handle), current.table.slots[i].object === object else {
        throw WaitError(status: .canceled, observed: object.signals)
      }
      if object.signals & signals != 0 { return object.signals }
      if !awaitChange(until: deadline) { throw WaitError(status: .timedOut, observed: object.signals) }
    }
  }

  /// wait_async: a packet to `port` when the object asserts one of
  /// `signals` (now, if it already does). `edge`: only on a change to it.
  public func waitAsync(_ handle: UInt32, port: UInt32, key: UInt64, signals: UInt32, edge: Bool) throws(Status) {
    try locked { () throws(Status) in
      let o = try lookup(handle, .wait)
      let p = try lookup(port, .write, as: PortObject.self)
      let w = AsyncWait(port: p, key: key, signals: signals, edge: edge, process: ObjectIdentifier(current),
                        handle: handle)
      let met = o.signals & signals
      if met != 0 && !edge {
        p.packets.append(Packet(key: key, type: 1, status: 0,
                                payload: (UInt64(met) | UInt64(o.signals) << 32, 1, UInt64(Self.now()), 0)))
        pthread_cond_broadcast(changed)
      } else {
        o.asyncWaits.append(w)
      }
    }
  }

  // MARK: Events, eventpairs, channels

  public func eventCreate() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let e = EventObject(self, type: ObjectType.event)
      e.refs = 1
      return try install(e, .eventDefault)
    }
  }

  func pair<T: Peered>(_ make: () -> T, _ rights: Rights) throws(Status) -> (UInt32, UInt32) {
    let a = make(), b = make()
    a.peer = b
    b.peer = a
    a.peerKoid = b.koid
    b.peerKoid = a.koid
    a.refs = 1
    b.refs = 1
    return (try install(a, rights), try install(b, rights))
  }

  public func eventPairCreate() throws(Status) -> (UInt32, UInt32) {
    try locked { () throws(Status) in try pair({ EventPairEnd(self, type: ObjectType.eventPair) }, .eventPairDefault) }
  }

  public func channelCreate() throws(Status) -> (UInt32, UInt32) {
    try locked { () throws(Status) in
      let ends = try pair({ ChannelEnd(self, type: ObjectType.channel) }, .channelDefault)
      for h in [ends.0, ends.1] { update(try lookup(h, []), set: Signals.writable) }
      return ends
    }
  }

  /// Under the lock: takes `handles` out of the caller's table for a
  /// message on `end`. On any failure every one of them is closed, as in
  /// Zircon: a write consumes its handles whatever happens.
  func carry(_ handles: [UInt32], on end: ChannelEnd?, _ failure: inout Status?) -> [(object: KernelObject, rights: Rights)] {
    var carried: [(object: KernelObject, rights: Rights)] = []
    for h in handles {
      guard let (object, rights) = try? take(h) else {
        failure = failure ?? .badHandle
        continue
      }
      if !rights.contains(.transfer) { failure = failure ?? .accessDenied }
      if let end, object === end || object === end.peer { failure = failure ?? .notSupported }
      carried.append((object, rights))
    }
    return carried
  }

  /// Under the lock: delivers a message to `end`'s peer, or to the call
  /// waiting for it there.
  func deliver(_ message: ChannelEnd.Message, from end: ChannelEnd) {
    let peer = end.peer as! ChannelEnd
    if message.bytes.count >= 4 {
      let txid = UInt32(message.bytes[0]) | UInt32(message.bytes[1]) << 8 | UInt32(message.bytes[2]) << 16
        | UInt32(message.bytes[3]) << 24
      if let waiting = peer.calls[txid], waiting == nil {
        peer.calls[txid] = message
        pthread_cond_broadcast(changed)
        return
      }
    }
    peer.queue.append(message)
    update(peer, set: Signals.readable)
  }

  public func channelWrite(_ handle: UInt32, bytes: [UInt8], handles: [UInt32]) throws(Status) {
    try locked { () throws(Status) in
      var failure: Status? = nil
      var end: ChannelEnd? = nil
      do throws(Status) {
        end = try lookup(handle, .write, as: ChannelEnd.self)
      } catch {
        failure = error
      }
      let carried = carry(handles, on: end, &failure)
      if bytes.count > 65_536 || handles.count > 64 { failure = failure ?? .outOfRange }
      if failure == nil, end?.peer == nil { failure = .peerClosed }
      if let failure {
        for c in carried { release(c.object) }
        throw failure
      }
      deliver(.init(bytes: bytes, handles: carried), from: end!)
    }
  }

  /// A message's sizes.
  public struct ReadResult: Equatable, Sendable {
    public var byteCount: Int
    public var handleCount: Int
  }

  /// A failed read; `needed` is set when the status is `bufferTooSmall`.
  public struct ReadError: Error {
    public var status: Status
    public var needed: ReadResult
  }

  /// Reads the next message into the buffers, installing its handles. If the
  /// buffers are too small, the message stays queued and the error says
  /// what it needs.
  public func channelRead(_ handle: UInt32, bytes: UnsafeMutableRawBufferPointer,
                          handles: UnsafeMutableBufferPointer<UInt32>) throws(ReadError) -> ReadResult
  {
    pthread_mutex_lock(lock)
    exitIfKilled()
    defer { pthread_mutex_unlock(lock) }
    func fail(_ s: Status, _ needed: ReadResult = ReadResult(byteCount: 0, handleCount: 0)) -> ReadError {
      ReadError(status: s, needed: needed)
    }
    let end: ChannelEnd
    do {
      end = try lookup(handle, .read, as: ChannelEnd.self)
    } catch {
      throw fail(error)
    }
    guard let message = end.queue.first else { throw fail(end.peer == nil ? .peerClosed : .shouldWait) }
    let needed = ReadResult(byteCount: message.bytes.count, handleCount: message.handles.count)
    guard message.bytes.count <= bytes.count, message.handles.count <= handles.count else {
      throw fail(.bufferTooSmall, needed)
    }
    var installed: [UInt32] = []
    for carried in message.handles {
      do {
        installed.append(try install(carried.object, carried.rights))
      } catch {
        for h in installed { _ = current.table.remove(current.table.index(h)!) }
        throw fail(error)
      }
    }
    end.queue.removeFirst()
    if end.queue.isEmpty { update(end, clear: Signals.readable) }
    message.bytes.withUnsafeBytes { bytes.copyMemory(from: $0) }
    for (i, h) in installed.enumerated() { handles[i] = h }
    return needed
  }

  /// A message read whole: its bytes, and its handles now the caller's.
  public struct Message: Sendable {
    public var bytes: [UInt8]
    public var handles: [UInt32]
  }

  /// channel_call: writes `bytes` (whose first four bytes the kernel sets
  /// to a txid of its own, high bit set) and waits for the reply that
  /// echoes it, which comes straight to this caller, never to a read.
  public func channelCall(_ handle: UInt32, bytes: [UInt8], handles: [UInt32], deadline: Int64) throws(Status)
    -> Message
  {
    try locked { () throws(Status) in
      var failure: Status? = nil
      var found: ChannelEnd? = nil
      do throws(Status) {
        found = try lookup(handle, [.read, .write], as: ChannelEnd.self)
      } catch {
        failure = error
      }
      let carried = carry(handles, on: found, &failure)
      if bytes.count < 4 || bytes.count > 65_536 || handles.count > 64 { failure = failure ?? .invalidArgs }
      if failure == nil, found?.peer == nil { failure = .peerClosed }
      if let failure {
        for c in carried { release(c.object) }
        throw failure
      }
      let end = found!
      repeat { lastTxid = (lastTxid &+ 1) & 0x7FFF_FFFF } while end.calls[lastTxid | 0x8000_0000] != nil
      let txid = lastTxid | 0x8000_0000
      var message = bytes
      for i in 0..<4 { message[i] = UInt8(truncatingIfNeeded: txid >> (8 * UInt32(i))) }
      end.calls[txid] = .some(nil)
      deliver(.init(bytes: message, handles: carried), from: end)
      while true {
        if case .some(.some(let reply)) = end.calls[txid] {
          end.calls[txid] = nil
          var installed: [UInt32] = []
          for c in reply.handles { installed.append(try install(c.object, c.rights)) }
          return Message(bytes: reply.bytes, handles: installed)
        }
        if end.peer == nil {
          end.calls[txid] = nil
          throw .peerClosed
        }
        if !awaitChange(until: deadline) {
          end.calls[txid] = nil
          throw .timedOut
        }
      }
    }
  }

  // MARK: Ports

  public func portCreate() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = PortObject(self, type: ObjectType.port)
      p.refs = 1
      return try install(p, .portDefault)
    }
  }

  public func portQueue(_ port: UInt32, _ packet: Packet) throws(Status) {
    try locked { () throws(Status) in
      let p = try lookup(port, .write, as: PortObject.self)
      var user = packet
      user.type = 0
      p.packets.append(user)
      pthread_cond_broadcast(changed)
    }
  }

  public func portWait(_ port: UInt32, deadline: Int64) throws(Status) -> Packet {
    try locked { () throws(Status) in
      let p = try lookup(port, .read, as: PortObject.self)
      while p.packets.isEmpty {
        guard current.table.index(port) != nil else { throw .canceled }
        if !awaitChange(until: deadline) { throw .timedOut }
      }
      return p.packets.removeFirst()
    }
  }

  /// port_cancel: drops the wait_asyncs `source` made to the port with
  /// `key`, and the packets they had queued.
  public func portCancel(_ port: UInt32, source: UInt32, key: UInt64) throws(Status) {
    try locked { () throws(Status) in
      let p = try lookup(port, .write, as: PortObject.self)
      let o = try lookup(source, [])
      let before = o.asyncWaits.count
      o.asyncWaits.removeAll { $0.port === p && $0.key == key }
      let queued = p.packets.count
      p.packets.removeAll { $0.key == key && $0.type == 1 }
      guard o.asyncWaits.count < before || p.packets.count < queued else { throw .notFound }
    }
  }

  // MARK: VMOs

  public func vmoCreate(size: Int) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      guard size >= 0, size <= 1 << 34 else { throw .outOfRange }
      let v = VMOObject(self, size: (size + 4095) & ~4095)
      v.refs = 1
      return try install(v, .vmoDefault)
    }
  }

  public func vmoSize(_ handle: UInt32) throws(Status) -> Int {
    try locked { () throws(Status) in try lookup(handle, [], as: VMOObject.self).size }
  }

  public func vmoRead(_ handle: UInt32, offset: Int, count: Int) throws(Status) -> [UInt8] {
    try locked { () throws(Status) in
      let v = try lookup(handle, .read, as: VMOObject.self)
      guard offset >= 0, count >= 0, offset <= v.size, count <= v.size - offset else { throw .outOfRange }
      return Array(UnsafeRawBufferPointer(start: v.base + offset, count: count))
    }
  }

  public func vmoWrite(_ handle: UInt32, offset: Int, _ bytes: [UInt8]) throws(Status) {
    try locked { () throws(Status) in
      let v = try lookup(handle, .write, as: VMOObject.self)
      guard offset >= 0, offset <= v.size, bytes.count <= v.size - offset else { throw .outOfRange }
      bytes.withUnsafeBytes { (v.base + offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
  }

  /// Maps a VMO's range; the mapping keeps the VMO alive until `unmap`.
  /// Hosted, every process shares one address space, so a mapping is
  /// the VMO's own memory.
  public func vmoMap(_ handle: UInt32, offset: Int, length: Int, writable: Bool) throws(Status) -> UnsafeMutableRawPointer {
    try locked { () throws(Status) in
      let v = try lookup(handle, writable ? [.map, .read, .write] : [.map, .read], as: VMOObject.self)
      guard offset >= 0, length > 0, offset % 4096 == 0, offset <= v.size, length <= v.size - offset else {
        throw .outOfRange
      }
      v.refs += 1
      mappings.append((v.base + offset, v))
      return v.base + offset
    }
  }

  var mappings: [(address: UnsafeMutableRawPointer, vmo: VMOObject)] = []

  public func vmoUnmap(_ address: UnsafeMutableRawPointer) throws(Status) {
    try locked { () throws(Status) in
      guard let i = mappings.firstIndex(where: { $0.address == address }) else { throw .notFound }
      let v = mappings.remove(at: i).vmo
      release(v)
    }
  }

  // MARK: Timers

  public func timerCreate() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let t = TimerObject(self, type: ObjectType.timer)
      t.refs = 1
      timers.append(t)
      return try install(t, .timerDefault)
    }
  }

  /// Arms a timer: at `deadline` it asserts SIGNALED (cleared now).
  public func timerSet(_ handle: UInt32, deadline: Int64) throws(Status) {
    try locked { () throws(Status) in
      let t = try lookup(handle, .write, as: TimerObject.self)
      t.deadline = deadline
      update(t, clear: Signals.signaled)
      startTimerThread()
      pthread_cond_broadcast(changed)
    }
  }

  public func timerCancel(_ handle: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let t = try lookup(handle, .write, as: TimerObject.self)
      t.deadline = nil
      update(t, clear: Signals.signaled)
    }
  }

  /// Under the lock: a thread that fires timers as their deadlines pass.
  func startTimerThread() {
    guard !timerThreadStarted else { return }
    timerThreadStarted = true
    var thread = pthread_t()
    let me = Unmanaged.passUnretained(self).toOpaque()
    pthread_create(&thread, nil, { arg in
      let k = Unmanaged<HostKernel>.fromOpaque(arg!).takeUnretainedValue()
      pthread_mutex_lock(k.lock)
      while true {
        k.timers.removeAll { $0.refs == 0 }
        let now = HostKernel.now()
        var next = HostKernel.infinite
        for t in k.timers {
          guard let d = t.deadline else { continue }
          if d <= now {
            t.deadline = nil
            k.update(t, set: Signals.signaled)
          } else {
            next = min(next, d)
          }
        }
        _ = k.awaitChange(until: next)
      }
    }, me)
    pthread_detach(thread)
  }

  // MARK: Jobs, processes, threads

  /// A handle to the root job, for the hosted boot (natively userboot
  /// passes it to the launcher).
  public func rootJobHandle() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      rootJob.refs += 1
      return try install(rootJob, .jobDefault)
    }
  }

  public func jobCreate(parent: UInt32) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let parent = try lookup(parent, .manageJob, as: JobObject.self)
      guard !parent.killed else { throw .badState }
      let j = JobObject(self, type: ObjectType.job)
      j.parent = parent
      j.refs = 1
      parent.children.append(j)
      return try install(j, .jobDefault)
    }
  }

  public func processCreate(job: UInt32, name: String) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let job = try lookup(job, .manageProcess, as: JobObject.self)
      guard !job.killed else { throw .badState }
      let p = ProcessObject(self, name: name, job: job)
      p.refs = 1
      job.processes.append(p)
      return try install(p, .processDefault)
    }
  }

  public func threadCreate(process: UInt32) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = try lookup(process, .manageThread, as: ProcessObject.self)
      guard !p.killed else { throw .badState }
      let t = ThreadObject(self, process: p)
      t.refs = 1
      p.refs += 1  // a thread keeps its process
      return try install(t, .threadDefault)
    }
  }

  final class Start {
    let kernel: HostKernel
    let thread: ThreadObject
    let body: (UInt32) -> Void
    let arg: UInt32
    init(_ kernel: HostKernel, _ thread: ThreadObject, _ body: @escaping (UInt32) -> Void, _ arg: UInt32) {
      self.kernel = kernel
      self.thread = thread
      self.body = body
      self.arg = arg
    }
  }

  /// Starts a thread running `body` in its process. With `arg`, a handle
  /// of the caller's moves into that process first (process_start's
  /// arg1), and `body` gets its number there.
  public func threadStart(_ thread: UInt32, arg: UInt32? = nil, _ body: @escaping (UInt32) -> Void) throws(Status) {
    try locked { () throws(Status) in
      let t = try lookup(thread, .write, as: ThreadObject.self)
      guard !t.started, !t.process.killed else { throw .badState }
      var argInProcess: UInt32 = 0
      if let arg {
        let (o, r) = try take(arg)
        argInProcess = try install(o, r, in: t.process)
      }
      t.started = true
      t.process.started = true
      t.process.running += 1
      t.refs += 1  // the running thread's own reference
      update(t, set: Signals.threadRunning)
      let start = Unmanaged.passRetained(Start(self, t, body, argInProcess)).toOpaque()
      var pt = pthread_t()
      guard pthread_create(&pt, nil, { arg in
        let s = Unmanaged<Start>.fromOpaque(arg!).takeRetainedValue()
        pthread_setspecific(s.kernel.currentKey, Unmanaged.passUnretained(s.thread).toOpaque())
        // The end key's destructor accounts for the thread's end, whether
        // the body returns or the thread exits in a kernel call.
        pthread_setspecific(s.kernel.endKey, Unmanaged.passRetained(s).toOpaque())
        s.body(s.arg)
        return nil
      }, start) == 0 else { throw .noResources }
      pthread_detach(pt)
    }
  }

  /// A thread finished: its process ends when its last thread does.
  func threadEnded(_ t: ThreadObject) {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    finish(t)
  }

  /// Under the lock.
  func finish(_ t: ThreadObject) {
    guard t.signals & Signals.terminated == 0 else { return }
    t.killed = true
    update(t, set: Signals.terminated, clear: Signals.threadRunning)
    t.process.running -= 1
    // The host's process is the Linux process: threads the kernel started
    // in it (Thread.spawn from a test or tool) don't end it.
    if t.process.running == 0 && t.process !== hostProcess { terminate(t.process, code: t.process.returnCode) }
    release(t)  // the running thread's own reference
  }

  /// Under the lock: a process ends. Its handles close, its threads exit
  /// at their next kernel call, and it signals TERMINATED.
  func terminate(_ p: ProcessObject, code: Int64) {
    guard p.signals & Signals.terminated == 0 else { return }
    p.killed = true
    p.returnCode = code
    var held: [KernelObject] = []
    for i in p.table.slots.indices where p.table.slots[i].object != nil { held.append(p.table.remove(i).0) }
    for o in held { release(o) }
    update(p, set: Signals.terminated)
    if let job = p.job { job.processes.removeAll { $0 === p } }
  }

  func kill(_ job: JobObject) {
    job.killed = true
    for p in job.processes { terminate(p, code: -1024) }
    for c in job.children { kill(c) }
    update(job, set: Signals.terminated)
  }

  /// task_kill: a job (and all under it), a process, or a thread.
  public func kill(_ task: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let o = try lookup(task, [])
      guard o is TaskObject else { throw .wrongType }
      _ = try lookup(task, .destroy)
      switch o {
      case let j as JobObject: kill(j)
      case let p as ProcessObject: terminate(p, code: -1024)
      case let t as ThreadObject:
        // It exits at its next kernel call, or now if it is waiting in one.
        t.killed = true
        pthread_cond_broadcast(changed)
      default: throw .wrongType
      }
    }
  }

  /// A handle to the calling process (natively, processargs' PROC_SELF).
  public func processSelf() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      p.refs += 1
      return try install(p, .processDefault)
    }
  }

  // MARK: Futexes

  /// A thread waiting on a futex word, until a wake marks it.
  final class FutexWaiter {
    let address: UInt
    let thread: ThreadObject?
    var woken = false
    init(address: UInt, thread: ThreadObject?) {
      self.address = address
      self.thread = thread
    }
  }

  /// futex_wait: sleeps while the word at `address` holds `current`, until
  /// a wake or `deadline`. `badState` if the word had already changed. The
  /// word is read under the kernel's lock, which a wake takes too, so no
  /// wake falls between the check and the sleep.
  public func futexWait(_ address: UnsafeMutablePointer<UInt32>, current value: UInt32, deadline: Int64) throws(Status) {
    try locked { () throws(Status) in
      let word = unsafe UnsafeRawPointer(address).assumingMemoryBound(to: Atomic<UInt32>.self)
      guard unsafe word.pointee.load(ordering: .sequentiallyConsistent) == value else { throw .badState }
      let waiter = FutexWaiter(address: UInt(bitPattern: address), thread: currentThread)
      futexWaiters.append(waiter)
      defer { futexWaiters.removeAll { $0 === waiter } }
      while !waiter.woken {
        if !awaitChange(until: deadline) { throw .timedOut }
      }
    }
  }

  /// futex_wake: wakes up to `count` threads waiting on `address`. A
  /// waiter whose thread was killed takes no wake.
  public func futexWake(_ address: UnsafeMutablePointer<UInt32>, count: Int) {
    try? locked { () throws(Status) in
      let a = UInt(bitPattern: address)
      var woken = 0
      for w in futexWaiters where woken < count && !w.woken && w.address == a {
        if let t = w.thread, t.killed || t.process.killed { continue }
        w.woken = true
        woken += 1
      }
      if woken > 0 { pthread_cond_broadcast(changed) }
    }
  }

  /// process_exit: the calling process ends with `code`; never returns.
  /// The host's own threads have no hosted process to end: the Linux
  /// process exits.
  public func exit(code: Int64) -> Never {
    pthread_mutex_lock(lock)
    let p = current
    guard p !== hostProcess else {
      pthread_mutex_unlock(lock)
      Glibc.exit(Int32(truncatingIfNeeded: code))
    }
    terminate(p, code: code)
    pthread_mutex_unlock(lock)
    pthread_exit(nil)
  }

  public struct ProcessInfo: Equatable, Sendable {
    public var returnCode: Int64
    public var started: Bool
    public var exited: Bool
  }

  public func processInfo(_ process: UInt32) throws(Status) -> ProcessInfo {
    try locked { () throws(Status) in
      let p = try lookup(process, .inspect, as: ProcessObject.self)
      return ProcessInfo(returnCode: p.returnCode, started: p.started, exited: p.signals & Signals.terminated != 0)
    }
  }

  /// Sleeps until `deadline` (nanosleep).
  public func sleep(until deadline: Int64) {
    pthread_mutex_lock(lock)
    exitIfKilled()
    while HostKernel.now() < deadline { _ = awaitChange(until: deadline) }
    pthread_mutex_unlock(lock)
  }
}
