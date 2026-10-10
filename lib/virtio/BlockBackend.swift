// SPDX-License-Identifier: BSD-3-Clause

// The block service's backend over virtio-blk (M3i): requests through one
// split queue, the data through a bounce region the device reaches, one
// request at a time. Memory the device can reach comes from a `DMAMemory`:
// natively pinned memory under croi's BTI (K9e), in tests memory the model
// device reads directly. The device is told of a request through its
// notify capability, and the backend then `wait`s until the used ring has
// it: natively for the device's interrupt, in tests not at all (the model
// serves a request when notified).

import Block
import BlockRing
import Sys

/// Memory a device reaches: zeroed bytes in this process and the address
/// the device uses for them, kept for the provider's life.
public protocol DMAMemory: AnyObject {
  func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64)
}

@safe public final class VirtioBlockBackend<W: Window>: BlockBackend, @unchecked Sendable {
  /// The service's blocks: 4096 bytes, eight of virtio's sectors.
  public let blockSize = 4096
  public let blockCount: UInt64
  public let readOnly: Bool
  public let features: UInt64
  let device: Device<W>
  let notify: W
  let notifyAt: Int
  let queue: SplitQueue
  let wait: () -> Void
  /// Kept: the rings and the bounce region live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  /// A request's header (16 bytes) and status (1), then the bounce region.
  let requestAddress: UInt
  let requestBus: UInt64
  let bounceBytes: Int
  public private(set) var requests = 0

  /// Negotiates, sets up queue 0 (`queueSize` entries, at most the
  /// device's) and a bounce region of `bounceBytes`, and sets DRIVER_OK.
  /// `notify` is the notify capability's window; `multiplier` its
  /// notify_off_multiplier.
  public init(device: Device<W>, notify: W, multiplier: UInt32, memory: DMAMemory, queueSize: Int = 64,
              bounceBytes: Int = 65536, wait: @escaping () -> Void) throws(Status)
  {
    self.device = device
    self.notify = notify
    self.wait = wait
    self.memory = memory
    self.bounceBytes = bounceBytes
    do throws(VirtioError) {
      features = try device.negotiate(Block.Feature.blockSize | Block.Feature.flush | Block.Feature.readOnly)
    } catch {
      throw .notSupported
    }
    readOnly = features & Block.Feature.readOnly != 0
    blockCount = Block.geometry(device).sectors / UInt64(blockSize / Block.sectorSize)
    var size = min(queueSize, device.queueSize(0))
    while size & (size - 1) != 0 { size &= size - 1 }  // a power of two
    guard size >= 3 else { throw .notSupported }
    let layout = QueueLayout(size: size)
    let rings = try unsafe memory.allocate(bytes: layout.bytes)
    queue = unsafe SplitQueue(layout: layout, unsafe: rings.pointer, busAddress: rings.bus)
    let region = try unsafe memory.allocate(bytes: 32 + bounceBytes)
    requestAddress = unsafe UInt(bitPattern: region.pointer)
    requestBus = unsafe region.bus
    let offset: Int
    do throws(VirtioError) {
      offset = try device.enable(queue: 0, size: size, descriptors: queue.descriptorsAddress,
                                 driver: queue.availableAddress, device: queue.usedAddress)
    } catch {
      throw .notSupported
    }
    notifyAt = offset * Int(multiplier)
    device.set(status: device.status | DeviceStatus.driverOK)
  }

  var request: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: requestAddress)! }

  /// One request: the header, `data` bytes of the bounce region (written
  /// by the device if `deviceWrites`), the status. Waits for it.
  func run(_ type: UInt32, sector: UInt64, data: Int, deviceWrites: Bool) -> BlockStatus {
    let header = Block.header(type: type, sector: sector)
    unsafe header.withUnsafeBytes { unsafe request.copyMemory(from: $0.baseAddress!, byteCount: 16) }
    unsafe request.storeBytes(of: UInt8(0xFF), toByteOffset: 16, as: UInt8.self)
    var buffers = [Buffer(address: requestBus, length: 16, deviceWrites: false)]
    if data > 0 { buffers.append(Buffer(address: requestBus + 32, length: UInt32(data), deviceWrites: deviceWrites)) }
    buffers.append(Buffer(address: requestBus + 16, length: 1, deviceWrites: true))
    guard queue.submit(buffers) != nil else { return .io }
    notify.write(notifyAt, width: 2, 0)
    while queue.completed().isEmpty { wait() }
    requests += 1
    switch unsafe request.load(fromByteOffset: 16, as: UInt8.self) {
    case Block.ok: return .ok
    case 2: return .invalid  // UNSUPP
    default: return .io
    }
  }

  func check(_ block: UInt64, _ bytes: Int) -> BlockStatus? {
    guard bytes % blockSize == 0, block <= blockCount, UInt64(bytes / blockSize) <= blockCount - block else {
      return .outOfRange
    }
    return nil
  }

  public func read(_ block: UInt64, into buffer: UnsafeMutableRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    if let bad = check(block, buffer.count) { return bad }
    return lock.withLock {
      var done = 0
      while done < buffer.count {
        let n = min(bounceBytes, buffer.count - done)
        let sector = (block * UInt64(blockSize) + UInt64(done)) / UInt64(Block.sectorSize)
        let s = run(Block.read, sector: sector, data: n, deviceWrites: true)
        guard s == .ok else { return s }
        unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + n)]).copyMemory(
          from: UnsafeRawBufferPointer(start: request + 32, count: n))
        done += n
      }
      return .ok
    }
  }

  public func write(_ block: UInt64, from buffer: UnsafeRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    if let bad = check(block, buffer.count) { return bad }
    guard !readOnly else { return .readOnly }
    return lock.withLock {
      var done = 0
      while done < buffer.count {
        let n = min(bounceBytes, buffer.count - done)
        unsafe UnsafeMutableRawBufferPointer(start: request + 32, count: n).copyMemory(
          from: UnsafeRawBufferPointer(rebasing: buffer[done..<(done + n)]))
        let sector = (block * UInt64(blockSize) + UInt64(done)) / UInt64(Block.sectorSize)
        let s = run(Block.write, sector: sector, data: n, deviceWrites: false)
        guard s == .ok else { return s }
        done += n
      }
      return .ok
    }
  }

  /// FLUSH if the device has a write cache to flush (§5.2.6.2), else
  /// writes are durable when done.
  public func flush() -> BlockStatus {
    guard features & Block.Feature.flush != 0 else { return .ok }
    return lock.withLock { run(Block.flush, sector: 0, data: 0, deviceWrites: false) }
  }
}
