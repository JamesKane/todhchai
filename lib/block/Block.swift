// SPDX-License-Identifier: BSD-3-Clause

// The block service (architecture §11): a device's blocks through rings in
// shared memory. A client opens a channel to `device` in the service's
// tree (`/svc/block/device`), opens its ring there, and attaches VMOs as
// buffers; then requests go through the ring (lib/block/ring), and the
// channel only sets up. Closing the channel ends the session.
//
// Natively the service sits on the NVMe, AHCI and virtio-blk drivers;
// hosted, on an image file (FileBackend).

import BlockRing
import IPC

@IPCLibrary(id: "todhchai.block", version: 1)
public enum BlockIPC {
  public enum BlockError: Int32, IPCErrorCode, Sendable {
    /// Entries that aren't a power of two from 1 to 4096, or a VMO that
    /// can't be mapped.
    case invalid = 1
    /// This channel's ring is already open.
    case alreadyOpen
    /// No buffer with that id.
    case notFound
    /// The session has as many buffers as it may.
    case tooMany
    case noResources
  }

  public struct DeviceInfo: Equatable, Sendable {
    public var blockSize: UInt32
    public var blockCount: UInt64
    /// The most blocks one request may move.
    public var maxTransfer: UInt32
    public var readOnly: Bool
  }

  /// A ring: the VMO to map (BlockRing's layout), and the client's end of
  /// the eventpair that kicks each side.
  public struct Ring: ~Copyable {
    public var vmo: Handle
    public var signal: Handle
  }

  public protocol Device {
    func info() -> DeviceInfo
    /// Opens this channel's ring, with `entries` in each direction.
    func open(entries: UInt32) throws(BlockError) -> Ring
    /// A VMO the ring's requests may move blocks to and from; its id. It
    /// is mapped writable if it can be, else only writes may use it.
    func attach(_ vmo: consuming Handle) throws(BlockError) -> UInt32
    /// Requests already taken still complete.
    func detach(_ buffer: UInt32) throws(BlockError)
  }
}

/// Where the blocks are: a driver natively, an image file hosted, memory in
/// tests. Called on the service's thread.
public protocol BlockBackend: AnyObject {
  var blockSize: Int { get }
  var blockCount: UInt64 { get }
  var readOnly: Bool { get }
  /// Fills `buffer` (whole blocks) from `block`.
  func read(_ block: UInt64, into buffer: UnsafeMutableRawBufferPointer, policy: CachePolicy) -> BlockStatus
  /// Writes `buffer` (whole blocks) from `block`.
  func write(_ block: UInt64, from buffer: UnsafeRawBufferPointer, policy: CachePolicy) -> BlockStatus
  /// Makes every completed write durable.
  func flush() -> BlockStatus
}

/// Blocks in memory: tests.
public final class MemoryBackend: BlockBackend {
  public let blockSize: Int
  public let blockCount: UInt64
  public let readOnly: Bool
  public private(set) var bytes: [UInt8]
  public private(set) var flushes = 0

  public init(blocks: UInt64, blockSize: Int = 4096, readOnly: Bool = false) {
    self.blockSize = blockSize
    blockCount = blocks
    self.readOnly = readOnly
    bytes = [UInt8](repeating: 0, count: Int(blocks) * blockSize)
  }

  public func read(_ block: UInt64, into buffer: UnsafeMutableRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let start = Int(block) * blockSize
    bytes.withUnsafeBytes { unsafe buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[start..<(start + buffer.count)])) }
    return .ok
  }

  public func write(_ block: UInt64, from buffer: UnsafeRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let start = Int(block) * blockSize
    bytes.withUnsafeMutableBytes { unsafe UnsafeMutableRawBufferPointer(rebasing: $0[start..<(start + buffer.count)]).copyMemory(from: buffer) }
    return .ok
  }

  public func flush() -> BlockStatus {
    flushes += 1
    return .ok
  }
}
