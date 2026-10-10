// SPDX-License-Identifier: BSD-3-Clause

// The block service's rings (architecture §4, §11): a submission ring the
// client fills and a completion ring the service fills, in one VMO both
// map. Each ring has one producer and one consumer. Indices run freely
// (UInt32, wrapping) and are masked by the ring's size, a power of two.
//
//     offset   what                          written by
//     0        magic "TDBR", version, entries  the service, once
//     64       submission tail               the client
//     128      submission head               the service
//     192      completion tail               the service
//     256      completion head               the client
//     320      service idle                  both (see below)
//     384      client waiting                both
//     512      submissions, 32 bytes each
//     ...      completions, 16 bytes each
//
// Each index has a cache line to itself. Waking goes through an eventpair:
// each side raises `kick` on the other. A side about to sleep clears its
// own `kick`, sets its flag ("service idle", "client waiting"), and looks
// at the ring once more; the other side, after publishing, swaps the flag
// back to 0 and kicks only if it was set. Flag and index are stored and
// loaded sequentially consistent, so one side always sees the other's
// work or its flag: no lost wakeups, and no kick while the other is busy.
//
// The service trusts nothing the client writes: an index that claims more
// than the ring holds ends the session, and each entry is read once, into
// a `Submission`, before it is checked.

import Synchronization

public enum BlockRing {
  /// "TDBR", little-endian.
  public static let magic: UInt32 = 0x5242_4454
  public static let version: UInt32 = 1
  /// The eventpair signal each side raises on the other: look at the ring.
  public static let kick: UInt32 = 1 << 24
  public static let headerSize = 512
  public static let submissionSize = 32
  public static let completionSize = 16
  public static let maxEntries = 4096

  static let submissionTail = 64
  static let submissionHead = 128
  static let completionTail = 192
  static let completionHead = 256
  static let serviceIdle = 320
  static let clientWaiting = 384

  /// The bytes a ring of `entries` needs.
  public static func size(entries: Int) -> Int { headerSize + entries * (submissionSize + completionSize) }

  /// Whether a ring may have `entries`.
  public static func isValid(entries: Int) -> Bool {
    entries >= 1 && entries <= maxEntries && entries & (entries - 1) == 0
  }
}

public enum BlockOperation: UInt8, Sendable {
  case read = 1
  case write
  /// Makes durable every write that completed before the flush was
  /// submitted. To order a write after it, wait for its completion.
  case flush
}

/// What caching a request may use (filesystem.md §7).
public enum CachePolicy: UInt8, Sendable {
  /// Served from and kept in caches.
  case cached = 0
  /// Straight to and from the device, past every cache. A write is not
  /// durable until a flush: the device's own cache may hold it.
  case uncached
  /// Reads only: read, and don't keep it (streaming assets).
  case readOnce
}

/// A completion's status: Zircon-style values would mean importing Sys; these
/// are the ring's own.
public enum BlockStatus: Int32, Error, Sendable {
  case ok = 0
  /// An unknown operation or policy, nonzero reserved bytes, or a policy
  /// the operation doesn't take.
  case invalid = 1
  /// Blocks past the device's end, or more than a request may move.
  case outOfRange
  /// No buffer with that id, or the range is outside it.
  case badBuffer
  case readOnly
  case io
}

/// A request: `count` blocks from device block `block`, to or from the
/// attached buffer `buffer` at `bufferBlock` blocks in. `tag` comes back in
/// its completion.
public struct Submission: Equatable, Sendable {
  public var operation: BlockOperation
  public var policy: CachePolicy
  public var buffer: UInt32
  public var tag: UInt64
  public var block: UInt64
  public var count: UInt32
  public var bufferBlock: UInt32

  public init(_ operation: BlockOperation, policy: CachePolicy = .cached, buffer: UInt32 = 0, tag: UInt64,
              block: UInt64 = 0, count: UInt32 = 0, bufferBlock: UInt32 = 0) {
    self.operation = operation
    self.policy = policy
    self.buffer = buffer
    self.tag = tag
    self.block = block
    self.count = count
    self.bufferBlock = bufferBlock
  }
}

public struct Completion: Equatable, Sendable {
  public var tag: UInt64
  public var status: BlockStatus
  /// Blocks moved.
  public var count: UInt32

  public init(tag: UInt64, status: BlockStatus, count: UInt32 = 0) {
    self.tag = tag
    self.status = status
    self.count = count
  }
}

/// The ring's memory: a mapping of the VMO, which outlives this.
@safe public struct RingMemory: @unchecked Sendable {
  let base: UnsafeMutableRawPointer
  public let entries: Int
  let mask: UInt32

  /// The ring at `base`, `length` bytes: the service's, laid out anew.
  public init(formatting base: UnsafeMutableRawPointer, length: Int, entries: Int) {
    precondition(BlockRing.isValid(entries: entries) && length >= BlockRing.size(entries: entries))
    unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: BlockRing.size(entries: entries))
    unsafe self.base = base
    self.entries = entries
    mask = UInt32(entries - 1)
    store(BlockRing.magic, 0)
    store(BlockRing.version, 4)
    store(UInt32(entries), 8)
    // The service starts asleep: the first publish kicks it.
    store(1, BlockRing.serviceIdle)
  }

  /// The ring at `base`, `length` bytes, as the service laid it out: the
  /// client's. Nil if it isn't one.
  public init?(mapping base: UnsafeMutableRawPointer, length: Int) {
    guard length >= BlockRing.headerSize else { return nil }
    let magic = unsafe base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
    let version = unsafe base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
    let entries = Int(unsafe base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
    guard magic == BlockRing.magic, version == BlockRing.version, BlockRing.isValid(entries: entries),
      length >= BlockRing.size(entries: entries)
    else { return nil }
    unsafe self.base = base
    self.entries = entries
    mask = UInt32(entries - 1)
  }

  func atomic(_ offset: Int) -> UnsafePointer<Atomic<UInt32>> {
    unsafe UnsafePointer((base + offset).assumingMemoryBound(to: Atomic<UInt32>.self))
  }

  func load(_ offset: Int) -> UInt32 { unsafe atomic(offset).pointee.load(ordering: .sequentiallyConsistent) }
  func store(_ value: UInt32, _ offset: Int) {
    unsafe atomic(offset).pointee.store(value, ordering: .sequentiallyConsistent)
  }
  func exchange(_ value: UInt32, _ offset: Int) -> UInt32 {
    unsafe atomic(offset).pointee.exchange(value, ordering: .sequentiallyConsistent)
  }

  func get<T: FixedWidthInteger>(_: T.Type, _ offset: Int) -> T {
    T(littleEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: T.self))
  }
  func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
    unsafe base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
  }

  func submissionOffset(_ index: UInt32) -> Int { BlockRing.headerSize + Int(index & mask) * BlockRing.submissionSize }
  func completionOffset(_ index: UInt32) -> Int {
    BlockRing.headerSize + entries * BlockRing.submissionSize + Int(index & mask) * BlockRing.completionSize
  }
}

/// The client's side: submits, and reaps completions.
public struct RingClient: Sendable {
  public let memory: RingMemory
  var submitted: UInt32 = 0
  var reaped: UInt32 = 0

  public init(_ memory: RingMemory) {
    self.memory = memory
    submitted = memory.load(BlockRing.submissionTail)
    reaped = memory.load(BlockRing.completionHead)
  }

  /// Requests submitted whose completions haven't been reaped. The client
  /// keeps this at most `entries`, so completions always have room.
  public var inFlight: Int { Int(submitted &- reaped) }

  /// Queues a request; false if `entries` are in flight. Unseen until
  /// `publish`.
  public mutating func submit(_ s: Submission) -> Bool {
    guard inFlight < memory.entries else { return false }
    let o = memory.submissionOffset(submitted)
    memory.put(s.operation.rawValue, o)
    memory.put(s.policy.rawValue, o + 1)
    memory.put(UInt16(0), o + 2)
    memory.put(s.buffer, o + 4)
    memory.put(s.tag, o + 8)
    memory.put(s.block, o + 16)
    memory.put(s.count, o + 24)
    memory.put(s.bufferBlock, o + 28)
    submitted &+= 1
    return true
  }

  /// Makes the queued requests visible; true if the service is idle and
  /// must be kicked.
  public func publish() -> Bool {
    memory.store(submitted, BlockRing.submissionTail)
    return memory.exchange(0, BlockRing.serviceIdle) != 0
  }

  /// The next completion, if there is one. A status the client doesn't know
  /// reads as `io`.
  public mutating func reap() -> Completion? {
    guard memory.load(BlockRing.completionTail) != reaped else { return nil }
    let o = memory.completionOffset(reaped)
    let c = Completion(tag: memory.get(UInt64.self, o),
                       status: BlockStatus(rawValue: memory.get(Int32.self, o + 8)) ?? .io,
                       count: memory.get(UInt32.self, o + 12))
    reaped &+= 1
    memory.store(reaped, BlockRing.completionHead)
    return c
  }

  /// Before sleeping until a kick (with the client's own `kick` already
  /// cleared): says so, and true if a completion came meanwhile, so don't.
  public func prepareToWait() -> Bool {
    memory.store(1, BlockRing.clientWaiting)
    if memory.load(BlockRing.completionTail) != reaped {
      memory.store(0, BlockRing.clientWaiting)
      return true
    }
    return false
  }
}

/// The service's side: takes requests, and posts completions.
public struct RingServer: Sendable {
  public let memory: RingMemory
  var taken: UInt32 = 0
  var completed: UInt32 = 0

  public init(_ memory: RingMemory) { self.memory = memory }

  /// What `take` found.
  public enum Taken: Equatable, Sendable {
    case request(Submission)
    /// An entry that isn't a valid request: complete it with `invalid`.
    case invalid(tag: UInt64)
  }

  /// A client that broke the ring's rules: end its session.
  public struct Corrupt: Error, Equatable, Sendable {}

  /// The next request, if there is one.
  public mutating func take() throws(Corrupt) -> Taken? {
    let tail = memory.load(BlockRing.submissionTail)
    let waiting = tail &- taken
    guard waiting <= UInt32(memory.entries) else { throw Corrupt() }
    guard waiting > 0 else { return nil }
    let room = UInt32(memory.entries) &- (completed &- memory.load(BlockRing.completionHead))
    // No room means more in flight than the ring holds.
    guard room <= UInt32(memory.entries), room > 0 else { throw Corrupt() }
    // Read once: the client may change the entry while it's looked at.
    let o = memory.submissionOffset(taken)
    let op = memory.get(UInt8.self, o), policy = memory.get(UInt8.self, o + 1)
    let reserved = memory.get(UInt16.self, o + 2), buffer = memory.get(UInt32.self, o + 4)
    let tag = memory.get(UInt64.self, o + 8), block = memory.get(UInt64.self, o + 16)
    let count = memory.get(UInt32.self, o + 24), bufferBlock = memory.get(UInt32.self, o + 28)
    taken &+= 1
    memory.store(taken, BlockRing.submissionHead)
    guard reserved == 0, let operation = BlockOperation(rawValue: op), let policy = CachePolicy(rawValue: policy) else {
      return .invalid(tag: tag)
    }
    return .request(Submission(operation, policy: policy, buffer: buffer, tag: tag, block: block, count: count,
                               bufferBlock: bufferBlock))
  }

  /// Posts a completion (`take` saw there was room). Unseen until `publish`.
  public mutating func complete(_ c: Completion) {
    let o = memory.completionOffset(completed)
    memory.put(c.tag, o)
    memory.put(c.status.rawValue, o + 8)
    memory.put(c.count, o + 12)
    completed &+= 1
  }

  /// Makes the posted completions visible; true if the client is waiting
  /// and must be kicked.
  public func publish() -> Bool {
    memory.store(completed, BlockRing.completionTail)
    return memory.exchange(0, BlockRing.clientWaiting) != 0
  }

  /// Before sleeping until a kick (with the service's own `kick` already
  /// cleared): says so, and true if a request came meanwhile, so don't.
  public func prepareToIdle() -> Bool {
    memory.store(1, BlockRing.serviceIdle)
    if memory.load(BlockRing.submissionTail) != taken {
      memory.store(0, BlockRing.serviceIdle)
      return true
    }
    return false
  }
}
