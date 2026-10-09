// SPDX-License-Identifier: BSD-3-Clause

/// Where a volume's regions are, in blocks. Blocks 0 and 1 hold the two
/// superblock copies; then the log, the free-space bitmap, and data.
public struct Layout: Equatable, Sendable {
  public var blockCount: UInt64
  public var logStart: UInt64
  public var logBlocks: UInt64
  public var bitmapStart: UInt64
  public var bitmapBlocks: UInt64
  public var dataStart: UInt64

  public static let blockSize = 4096
  /// B+tree nodes: 16 KiB, four blocks (filesystem.md §3).
  public static let nodeBlocks = 4

  /// The layout for `blockCount` blocks. The log defaults to 1% of the
  /// volume, between 1 and 64 MiB.
  public init(blockCount: UInt64, logBlocks: UInt64? = nil) throws(TaisceError) {
    let bitsPerBlock = UInt64(Self.blockSize * 8)
    let log = logBlocks ?? min(max(blockCount / 100, 256), 16_384)
    let bitmap = (blockCount + bitsPerBlock - 1) / bitsPerBlock
    self.blockCount = blockCount
    logStart = 2
    self.logBlocks = log
    bitmapStart = 2 + log
    bitmapBlocks = bitmap
    dataStart = 2 + log + bitmap
    // Room for at least a few nodes of data.
    guard dataStart + UInt64(Self.nodeBlocks) * 8 <= blockCount else { throw .tooSmall }
  }
}

/// The volume's root record, in two copies (blocks 0 and 1). Each write
/// goes to the copy the generation picks, so a torn write leaves the other
/// copy intact, and the newest valid copy wins at mount.
public struct Superblock: Equatable, Sendable {
  public static let magic: UInt64 = 0x0000_6563_7369_6154  // "Taisce\0\0", little-endian
  public static let version: UInt32 = 1  // S1: checksummed copy-on-write trees

  public var layout: Layout
  public var generation: UInt64
  public var uuid: [UInt8]  // 16 bytes
  public var label: [UInt8]  // UTF-8, at most 64 bytes
  public var createdNs: UInt64
  /// The catalog's root: the tree of every tree's root pointer.
  public var catalogRoot: NodePointer
  public var nextInode: UInt64
  /// The log's epoch: only records written in it are replayed. Each
  /// checkpoint starts a new one, at the start of the log.
  public var logEpoch: UInt64

  public init(layout: Layout, uuid: [UInt8], label: [UInt8], createdNs: UInt64) {
    self.layout = layout
    generation = 1
    self.uuid = uuid
    self.label = Array(label.prefix(64))
    self.createdNs = createdNs
    catalogRoot = .null
    nextInode = 2  // 1 is the root directory
    logEpoch = 1
  }

  // The block: fields at fixed offsets, CRC-32C of the rest in its last 4 bytes.
  static let checksumOffset = Layout.blockSize - 4

  public func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: Layout.blockSize)
    b.put(Self.magic, at: 0)
    b.put(Self.version, at: 8)
    b.put(UInt32(Layout.blockSize), at: 12)
    b.put(generation, at: 16)
    b.put(layout.blockCount, at: 24)
    b.put(layout.logStart, at: 32)
    b.put(layout.logBlocks, at: 40)
    b.put(layout.bitmapStart, at: 48)
    b.put(layout.bitmapBlocks, at: 56)
    b.put(layout.dataStart, at: 64)
    b.put(UInt32(Layout.nodeBlocks), at: 72)
    b.put(createdNs, at: 80)
    catalogRoot.put(into: &b, at: 88)  // to 120
    b.put(nextInode, at: 120)
    b.put(logEpoch, at: 128)
    b.put(bytes: uuid, at: 144)
    b.put(UInt8(label.count), at: 160)
    b.put(bytes: label, at: 161)
    b.put(CRC32C.checksum(b, 0..<Self.checksumOffset), at: Self.checksumOffset)
    return b
  }

  /// A superblock from a block, or nil if it isn't a valid one.
  public static func decode(_ b: [UInt8]) throws(TaisceError) -> Superblock? {
    guard b.count >= Layout.blockSize, b.get(UInt64.self, at: 0) == magic,
      b.get(UInt32.self, at: checksumOffset) == CRC32C.checksum(b, 0..<checksumOffset)
    else { return nil }
    let version = b.get(UInt32.self, at: 8)
    guard version == Self.version else { throw .unsupportedVersion(version) }
    guard b.get(UInt32.self, at: 12) == UInt32(Layout.blockSize), b.get(UInt32.self, at: 72) == UInt32(Layout.nodeBlocks)
    else { throw .corrupt(.superblockLayout) }
    let layout = Layout(
      unchecked: b.get(UInt64.self, at: 24), logStart: b.get(UInt64.self, at: 32), logBlocks: b.get(UInt64.self, at: 40),
      bitmapStart: b.get(UInt64.self, at: 48), bitmapBlocks: b.get(UInt64.self, at: 56),
      dataStart: b.get(UInt64.self, at: 64))
    guard layout.logStart == 2, layout.bitmapStart == layout.logStart + layout.logBlocks,
      layout.dataStart == layout.bitmapStart + layout.bitmapBlocks, layout.dataStart < layout.blockCount
    else { throw .corrupt(.superblockLayout) }
    let labelCount = min(Int(b[160]), 64)
    var s = Superblock(layout: layout, uuid: b.get(bytes: 16, at: 144), label: b.get(bytes: labelCount, at: 161),
                       createdNs: b.get(UInt64.self, at: 80))
    s.generation = b.get(UInt64.self, at: 16)
    s.catalogRoot = NodePointer.get(b, at: 88)
    s.nextInode = b.get(UInt64.self, at: 120)
    s.logEpoch = b.get(UInt64.self, at: 128)
    return s
  }

  /// The copy this generation is written to.
  public var slot: UInt64 { generation % 2 }
}

extension Layout {
  init(unchecked blockCount: UInt64, logStart: UInt64, logBlocks: UInt64, bitmapStart: UInt64, bitmapBlocks: UInt64,
       dataStart: UInt64) {
    self.blockCount = blockCount
    self.logStart = logStart
    self.logBlocks = logBlocks
    self.bitmapStart = bitmapStart
    self.bitmapBlocks = bitmapBlocks
    self.dataStart = dataStart
  }
}
