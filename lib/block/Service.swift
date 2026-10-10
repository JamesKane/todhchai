// SPDX-License-Identifier: BSD-3-Clause

// The block service's side: Device on each channel, a ring per session
// drained on the dispatcher's thread, and the service's Node tree:
//
//     device    the Device protocol (a service node)
//     status    the device and what has been done to it

import BlockRing
import IPC
import Node

/// Serves a backend's blocks. Everything runs on the dispatcher's thread.
public final class BlockService: @unchecked Sendable {
  public let backend: any BlockBackend
  /// What `status` calls the device.
  public let name: String
  let dispatcher: IPCDispatcher

  /// The most blocks one request moves.
  public static let maxTransfer: UInt32 = 256
  /// The most buffers one session attaches.
  public static let maxBuffers = 64
  /// Requests taken from one ring before other channels get a turn.
  static let batch = 64

  public struct Counts: Equatable, Sendable {
    public var sessions = 0
    public var reads = 0
    public var readBlocks: UInt64 = 0
    public var writes = 0
    public var writtenBlocks: UInt64 = 0
    public var flushes = 0
    /// Requests that failed.
    public var errors = 0
    /// Sessions ended for breaking the ring's rules.
    public var corrupt = 0
  }

  let counted = Locked(Counts())
  public var counts: Counts { counted.withLock { $0 } }

  public init(backend: any BlockBackend, name: String, dispatcher: IPCDispatcher) {
    self.backend = backend
    self.name = name
    self.dispatcher = dispatcher
  }

  /// Puts `device` and `status` in `tree`.
  public func publish(in tree: NodeTree) {
    tree.service("device") { [self] (channel: consuming Handle) throws(Status) in try serve(channel) }
    tree.text("status") { [self] in status }
  }

  /// Serves Device on `channel`.
  public func serve(_ channel: consuming Handle) throws(Status) {
    let owner = SessionOwner(Session(self))
    try dispatcher.add(BlockIPC.DeviceServer(channel: channel, impl: DeviceSession(owner: owner)))
    counted.withLock { $0.sessions += 1 }
  }

  public var info: BlockIPC.DeviceInfo {
    BlockIPC.DeviceInfo(blockSize: UInt32(backend.blockSize), blockCount: backend.blockCount,
                        maxTransfer: Self.maxTransfer, readOnly: backend.readOnly)
  }

  public var status: String {
    let c = counts
    return """
      device \(name)
      block-size \(backend.blockSize)
      blocks \(backend.blockCount)
      read-only \(backend.readOnly ? "yes" : "no")
      sessions \(c.sessions)
      reads \(c.reads) blocks \(c.readBlocks)
      writes \(c.writes) blocks \(c.writtenBlocks)
      flushes \(c.flushes)
      errors \(c.errors)
      corrupt \(c.corrupt)

      """
  }

  /// Does one request.
  func perform(_ taken: RingServer.Taken, _ session: Session) -> Completion {
    let s: Submission
    switch taken {
    case .request(let request):
      s = request
    case .invalid(let tag):
      counted.withLock { $0.errors += 1 }
      return Completion(tag: tag, status: .invalid)
    }
    let status = s.operation == .flush ? (s.policy == .cached ? backend.flush() : .invalid) : transfer(s, session)
    counted.withLock { c in
      guard status == .ok else { return c.errors += 1 }
      switch s.operation {
      case .read:
        c.reads += 1
        c.readBlocks += UInt64(s.count)
      case .write:
        c.writes += 1
        c.writtenBlocks += UInt64(s.count)
      case .flush:
        c.flushes += 1
      }
    }
    return Completion(tag: s.tag, status: status, count: status == .ok ? s.count : 0)
  }

  /// A read or write, checked.
  func transfer(_ s: Submission, _ session: Session) -> BlockStatus {
    let write = s.operation == .write
    guard s.count > 0, !(write && s.policy == .readOnce) else { return .invalid }
    guard s.count <= Self.maxTransfer, s.block <= backend.blockCount, UInt64(s.count) <= backend.blockCount - s.block
    else { return .outOfRange }
    if write && backend.readOnly { return .readOnly }
    guard let buffer = session.buffer(s.buffer) else { return .badBuffer }
    let start = Int(s.bufferBlock) * backend.blockSize, length = Int(s.count) * backend.blockSize
    guard start + length <= buffer.mapping.length, write || buffer.writable else { return .badBuffer }
    let address = unsafe buffer.mapping.address + start
    return unsafe write
      ? backend.write(s.block, from: UnsafeRawBufferPointer(start: address, count: length), policy: s.policy)
      : backend.read(s.block, into: UnsafeMutableRawBufferPointer(start: address, count: length), policy: s.policy)
  }
}

/// A VMO a session attached.
final class Buffer {
  let mapping: Mapping
  let writable: Bool
  init(_ mapping: consuming Mapping, writable: Bool) {
    self.mapping = mapping
    self.writable = writable
  }
}

/// One channel's session: its ring and buffers.
final class Session {
  let service: BlockService
  var open: OpenRing?
  var watch: UInt64?
  /// Attached buffers by id: a handful (maxBuffers), so an array (no
  /// hashed collections in tier 0).
  var buffers: [(id: UInt32, buffer: Buffer)] = []

  func buffer(_ id: UInt32) -> Buffer? { buffers.first { $0.id == id }?.buffer }
  var lastBuffer: UInt32 = 0

  init(_ service: BlockService) { self.service = service }

  /// Takes what the client has submitted, on a kick. False to stop watching.
  func drain(_ observed: UInt32) -> Bool {
    guard observed & Signals.peerClosed == 0, let open else { return end() }
    try? open.signal.signal(clear: BlockRing.kick, set: 0)
    var taken = 0
    while true {
      do throws(RingServer.Corrupt) {
        while taken < BlockService.batch, let request = try open.ring.take() {
          open.ring.complete(service.perform(request, self))
          taken += 1
        }
      } catch {
        service.counted.withLock { $0.corrupt += 1 }
        return end()
      }
      if open.ring.publish() { try? open.signal.signalPeer(set: BlockRing.kick) }
      if taken >= BlockService.batch {
        // Come back after the dispatcher's other work.
        try? open.signal.signal(set: BlockRing.kick)
        break
      }
      if !open.ring.prepareToIdle() { break }
    }
    return true
  }

  /// Ends the ring (the client's end sees its peer close).
  func end() -> Bool {
    open = nil
    watch = nil
    return false
  }

  /// The channel closed.
  func close() {
    if let watch { service.dispatcher.unwatch(watch) }
    _ = end()
    buffers = []
    service.counted.withLock { $0.sessions -= 1 }
  }
}

/// A session's ring: the service's side, the mapping it lives in, and the
/// service's end of the eventpair (the dispatcher watches a duplicate).
final class OpenRing {
  var ring: RingServer
  let mapping: Mapping
  let signal: Handle

  init(_ ring: RingServer, _ mapping: consuming Mapping, _ signal: consuming Handle) {
    self.ring = ring
    self.mapping = mapping
    self.signal = signal
  }
}

/// Ends the session when the Device server, which alone holds it, goes.
final class SessionOwner {
  let session: Session
  init(_ session: Session) { self.session = session }
  deinit { session.close() }
}

struct DeviceSession: BlockIPC.DeviceHandler {
  let owner: SessionOwner
  var session: Session { owner.session }

  mutating func info() -> BlockIPC.DeviceInfo { session.service.info }

  mutating func open(entries: UInt32) throws(BlockIPC.BlockError) -> BlockIPC.Ring {
    let session = self.session
    guard session.open == nil else { throw .alreadyOpen }
    guard BlockRing.isValid(entries: Int(entries)) else { throw .invalid }
    do throws(Status) {
      let size = BlockRing.size(entries: Int(entries))
      let vmo = try VMO.create(size: size)
      let mapping = try VMO.map(vmo, length: size)
      let memory = unsafe RingMemory(formatting: mapping.address, length: size, entries: Int(entries))
      let ends = try EventPair.create()
      let mine = ends.a, theirs = ends.b
      let signal = try mine.duplicate()
      session.open = OpenRing(RingServer(memory), mapping, signal)
      session.watch = try session.service.dispatcher.watch(mine, signals: BlockRing.kick | Signals.peerClosed) {
        [session] observed in session.drain(observed)
      }
      return BlockIPC.Ring(vmo: vmo, signal: theirs)
    } catch {
      _ = session.end()
      throw .noResources
    }
  }

  mutating func attach(_ vmo: consuming Handle) throws(BlockIPC.BlockError) -> UInt32 {
    let session = self.session
    guard session.buffers.count < BlockService.maxBuffers else { throw .tooMany }
    let buffer: Buffer
    do throws(Status) {
      let size = try VMO.size(vmo)
      do throws(Status) {
        buffer = Buffer(try VMO.map(vmo, length: size), writable: true)
      } catch {
        buffer = Buffer(try VMO.map(vmo, length: size, writable: false), writable: false)
      }
    } catch {
      throw .invalid
    }
    session.lastBuffer += 1
    session.buffers.append((session.lastBuffer, buffer))
    return session.lastBuffer
  }

  mutating func detach(_ buffer: UInt32) throws(BlockIPC.BlockError) {
    guard let i = session.buffers.firstIndex(where: { $0.id == buffer }) else { throw .notFound }
    session.buffers.remove(at: i)
  }
}
