// SPDX-License-Identifier: BSD-3-Clause

// A block session from the client's side: the ring, mapped, and a buffer
// attached for the conveniences.
//
//     var disk = try BlockClient(try namespace.connect("/svc/block/device"))
//     try disk.write(8, bytes, policy: .uncached)
//     try disk.flush()
//     let back = try disk.read(8, count: 1)
//
// Or drive the ring: `submit` any number, `publish`, then `wait` for each
// completion. Requests may use other buffers too (`attach`).

import BlockRing
import IPC

public struct BlockClient: ~Copyable {
  public typealias Failure = IPCError<BlockIPC.BlockError>

  public var device: BlockIPC.DeviceClient
  public let info: BlockIPC.DeviceInfo
  public private(set) var ring: RingClient
  let ringMapping: Mapping
  /// The client's end of the ring's eventpair.
  let signal: Handle
  /// The buffer `read` and `write` go through, attached as `bufferID`.
  public let buffer: Mapping
  public let bufferID: UInt32
  var lastTag: UInt64 = 0

  /// A session on a channel to a block service's `device`, with a ring of
  /// `entries` and a buffer of `bufferBlocks`.
  public init(_ channel: consuming Handle, entries: Int = 64, bufferBlocks: Int = 256) throws(Failure) {
    var device = BlockIPC.DeviceClient(channel: channel)
    let info: BlockIPC.DeviceInfo
    do throws(IPCError<Never>) { info = try device.info() } catch { throw Self.lift(error) }
    let opened = try device.open(entries: UInt32(clamping: entries))
    let ringVMO = opened.vmo, signal = opened.signal
    var mapped: Mapped
    do throws(Status) {
      mapped = try Mapped(ring: ringVMO, bufferBytes: max(1, bufferBlocks) * Int(info.blockSize))
    } catch {
      throw .transport(error)
    }
    guard let memory = RingMemory(mapping: mapped.ring.address, length: mapped.ring.length) else {
      throw .transport(.badState)
    }
    bufferID = try device.attach(mapped.bufferVMO)
    ring = RingClient(memory)
    ringMapping = mapped.ring
    buffer = mapped.buffer
    self.signal = signal
    self.device = device
    self.info = info
  }

  /// Attaches another buffer: its id for `Submission.buffer`.
  public mutating func attach(_ vmo: consuming Handle) throws(Failure) -> UInt32 { try device.attach(vmo) }

  /// A tag no request of this client's has had.
  public mutating func tag() -> UInt64 {
    lastTag += 1
    return lastTag
  }

  /// Queues a request; false if as many are in flight as the ring holds.
  public mutating func submit(_ s: Submission) -> Bool { ring.submit(s) }

  /// Hands the queued requests to the service.
  public func publish() {
    if ring.publish() { try? signal.signalPeer(set: BlockRing.kick) }
  }

  /// The next completion, waiting until `deadline` for it (nil if it
  /// passes). Throws `io` if the service ended the session.
  public mutating func wait(deadline: Int64 = infiniteDeadline) throws(BlockStatus) -> Completion? {
    while true {
      if let c = ring.reap() { return c }
      try? signal.signal(clear: BlockRing.kick, set: 0)
      if ring.prepareToWait() { continue }
      let observed: UInt32
      do throws(Status) {
        observed = try signal.wait(for: BlockRing.kick | Signals.peerClosed, deadline: deadline)
      } catch .timedOut {
        return nil
      } catch {
        throw .io
      }
      if observed & Signals.peerClosed != 0 {
        if let c = ring.reap() { return c }
        throw .io
      }
    }
  }

  // MARK: One request at a time, through the buffer

  /// Does `s` with nothing else in flight.
  mutating func run(_ s: Submission) throws(BlockStatus) {
    precondition(ring.inFlight == 0, "BlockClient's conveniences need the ring to themselves")
    _ = submit(s)
    publish()
    guard let c = try wait() else { throw .io }
    guard c.status == .ok else { throw c.status }
  }

  /// Blocks one request (and the buffer) can take.
  var chunk: Int { min(Int(info.maxTransfer), buffer.length / Int(info.blockSize)) }

  /// `count` blocks from `block`.
  public mutating func read(_ block: UInt64, count: Int, policy: CachePolicy = .cached) throws(BlockStatus) -> [UInt8] {
    let size = Int(info.blockSize)
    var out: [UInt8] = []
    out.reserveCapacity(count * size)
    var done = 0
    while done < count {
      let n = min(chunk, count - done)
      try run(Submission(.read, policy: policy, buffer: bufferID, tag: tag(), block: block + UInt64(done),
                         count: UInt32(n)))
      out += UnsafeRawBufferPointer(start: buffer.address, count: n * size)
      done += n
    }
    return out
  }

  /// Writes whole blocks from `block`.
  public mutating func write(_ block: UInt64, _ bytes: [UInt8], policy: CachePolicy = .cached) throws(BlockStatus) {
    let size = Int(info.blockSize)
    guard bytes.count % size == 0 else { throw .invalid }
    var done = 0
    while done < bytes.count / size {
      let n = min(chunk, bytes.count / size - done)
      bytes.withUnsafeBytes { b in
        buffer.address.copyMemory(from: b.baseAddress! + done * size, byteCount: n * size)
      }
      try run(Submission(.write, policy: policy, buffer: bufferID, tag: tag(), block: block + UInt64(done),
                         count: UInt32(n)))
      done += n
    }
  }

  /// Makes every completed write durable.
  public mutating func flush() throws(BlockStatus) { try run(Submission(.flush, tag: tag())) }

  /// The ring mapped, and a buffer made and mapped.
  struct Mapped: ~Copyable {
    var ring: Mapping
    var buffer: Mapping
    var bufferVMO: Handle

    init(ring vmo: borrowing Handle, bufferBytes: Int) throws(Status) {
      let ring = try VMO.map(vmo, length: try VMO.size(vmo))
      let bufferVMO = try VMO.create(size: bufferBytes)
      let buffer = try VMO.map(bufferVMO, length: try VMO.size(bufferVMO))
      self.ring = ring
      self.buffer = buffer
      self.bufferVMO = bufferVMO
    }
  }

  /// A failure of a call that has no error of its own.
  static func lift(_ e: IPCError<Never>) -> Failure {
    switch e {
    case .transport(let s): .transport(s)
    case .wire(let w): .wire(w)
    }
  }
}
