// SPDX-License-Identifier: BSD-3-Clause

/// Where a volume's blocks live. Natively this is the `block` service's
/// ring (architecture §9); hosted, a file or memory.
///
/// `flush` is a barrier: every write before it is durable before any write
/// after it. Between flushes, writes may land in any order, or not at all,
/// if power fails; the crash harness (RecordingDevice) explores exactly that.
public protocol BlockDevice {
  /// Bytes a block: Taisce uses 4096.
  var blockSize: Int { get }
  var blockCount: UInt64 { get }
  /// Reads `count` blocks from `block`.
  mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8]
  /// Writes whole blocks from `block`.
  mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError)
  mutating func flush() throws(TaisceError)
}

extension BlockDevice {
  func check(_ block: UInt64, blocks: Int) throws(TaisceError) {
    guard blocks >= 0, block <= blockCount, UInt64(blocks) <= blockCount - block else { throw .outOfRange }
  }
}

/// Blocks in memory: tests, fuzzers and the crash harness.
public struct MemoryDevice: BlockDevice {
  public let blockSize: Int
  public let blockCount: UInt64
  public var storage: [UInt8]

  public init(blocks: UInt64, blockSize: Int = 4096) {
    self.blockSize = blockSize
    blockCount = blocks
    storage = [UInt8](repeating: 0, count: Int(blocks) * blockSize)
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    try check(block, blocks: count)
    let start = Int(block) * blockSize
    return Array(storage[start..<(start + count * blockSize)])
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0 else { throw .outOfRange }
    try check(block, blocks: bytes.count / blockSize)
    let start = Int(block) * blockSize
    storage.replaceSubrange(start..<(start + bytes.count), with: bytes)
  }

  public mutating func flush() throws(TaisceError) {}
}

/// A device that records every write and flush made through it, so the
/// crash harness can rebuild the disk as it was at any point, and as power
/// loss could have left it (filesystem.md §9).
public struct RecordingDevice<Base: BlockDevice>: BlockDevice {
  public enum Operation: Equatable, Sendable {
    case write(block: UInt64, bytes: [UInt8])
    case flush
  }

  public var base: Base
  public private(set) var log: [Operation] = []

  public init(_ base: Base) { self.base = base }

  public var blockSize: Int { base.blockSize }
  public var blockCount: UInt64 { base.blockCount }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    try base.read(block, count: count)
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    try base.write(block, bytes)
    log.append(.write(block: block, bytes: bytes))
  }

  public mutating func flush() throws(TaisceError) {
    try base.flush()
    log.append(.flush)
  }

  /// Forgets what was recorded (after setting up the state to crash from).
  public mutating func clearLog() { log = [] }
}

extension MemoryDevice {
  /// This device with `operations` applied, as if they reached the disk.
  public func applying(_ operations: some Sequence<RecordingDevice<MemoryDevice>.Operation>) -> MemoryDevice {
    var d = self
    for op in operations {
      if case .write(let block, let bytes) = op { try? d.write(block, bytes) }
    }
    return d
  }
}
