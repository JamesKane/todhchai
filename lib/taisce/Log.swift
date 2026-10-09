// SPDX-License-Identifier: BSD-3-Clause

/// The write-ahead log (S0's commit layer; S1 replaces it with copy-on-write
/// and a superblock flip, filesystem.md §2). Physical redo: a transaction
/// group's changed blocks are written into the log as records, then a
/// barrier, which is the commit point, then in place. Mount replays every
/// complete group in the log, in order; replaying twice is harmless.
///
/// A record is a header block and the blocks it carries:
///
///     header  magic "TLog" u32, flags u16 (1: the group's last record),
///             count u16, epoch u64, seq u64, txg u64, catalog root u64,
///             next inode u64, CRC-32C u32 (of the header with this field
///             zero, then the blocks), then `count` target block numbers
///     blocks  `count` blocks, each to be written at its target
///
/// The log is used from its start; when the next group won't fit before its
/// end, a checkpoint (barrier, superblock, barrier) starts a new epoch at
/// the start. Records from an older epoch are never replayed, however
/// valid they look.
public enum Log {
  static let magic: UInt32 = 0x676F_4C54  // "TLog"
  static let headerFields = 64
  /// Blocks one record can carry.
  public static let maxBlocks = (Layout.blockSize - headerFields) / 8

  public struct Record {
    public var last: Bool
    public var epoch: UInt64
    public var seq: UInt64
    public var txg: UInt64
    public var catalogRoot: UInt64
    public var nextInode: UInt64
    public var targets: [UInt64]
    public var blocks: [UInt8]  // targets.count blocks

    /// The header block followed by the blocks.
    func encode() -> [UInt8] {
      var h = [UInt8](repeating: 0, count: Layout.blockSize)
      h.put(Log.magic, at: 0)
      h.put(UInt16(last ? 1 : 0), at: 4)
      h.put(UInt16(targets.count), at: 6)
      h.put(epoch, at: 8)
      h.put(seq, at: 16)
      h.put(txg, at: 24)
      h.put(catalogRoot, at: 32)
      h.put(nextInode, at: 40)
      for (i, t) in targets.enumerated() { h.put(t, at: Log.headerFields + 8 * i) }
      let whole = h + blocks
      var out = whole
      out.put(CRC32C.checksum(whole), at: 48)
      return out
    }
  }

  /// The record at `block`, if a valid one of `epoch` and `seq` is there
  /// and fits before `end`.
  static func read<D: BlockDevice>(_ device: inout D, at block: UInt64, end: UInt64, epoch: UInt64, seq: UInt64)
    throws(TaisceError) -> Record?
  {
    guard block < end else { return nil }
    var h = try device.read(block, count: 1)
    guard h.get(UInt32.self, at: 0) == magic, h.get(UInt64.self, at: 8) == epoch, h.get(UInt64.self, at: 16) == seq
    else { return nil }
    let count = Int(h.get(UInt16.self, at: 6))
    guard count <= maxBlocks, block + 1 + UInt64(count) <= end else { return nil }
    let blocks = try device.read(block + 1, count: count)
    let stored = h.get(UInt32.self, at: 48)
    h.put(UInt32(0), at: 48)
    guard CRC32C.checksum(h + blocks) == stored else { return nil }
    return Record(
      last: h.get(UInt16.self, at: 4) & 1 != 0, epoch: epoch, seq: seq, txg: h.get(UInt64.self, at: 24),
      catalogRoot: h.get(UInt64.self, at: 32), nextInode: h.get(UInt64.self, at: 40),
      targets: (0..<count).map { h.get(UInt64.self, at: headerFields + 8 * $0) }, blocks: blocks)
  }

  /// Replays the log onto `device` and checkpoints: every complete group
  /// is written in place, and the superblock takes the newest's state.
  /// Returns how many groups were replayed.
  @discardableResult
  public static func replay<D: BlockDevice>(_ device: inout D) throws(TaisceError) -> Int {
    var sb = try Volume<D>.newestSuperblock(&device)
    let end = sb.layout.logStart + sb.layout.logBlocks
    var at = sb.layout.logStart
    var seq: UInt64 = 0
    var pending: [Record] = []
    var groups = 0
    while let r = try read(&device, at: at, end: end, epoch: sb.logEpoch, seq: seq) {
      pending.append(r)
      at += 1 + UInt64(r.targets.count)
      seq += 1
      guard r.last else { continue }
      for p in pending {
        for (i, target) in p.targets.enumerated() {
          let start = i * Layout.blockSize
          try device.write(target, Array(p.blocks[start..<(start + Layout.blockSize)]))
        }
      }
      sb.catalogRoot = r.catalogRoot
      sb.nextInode = r.nextInode
      pending = []
      groups += 1
    }
    // Checkpoint: what was replayed is durable before the superblock says
    // so, and the log starts over in a new epoch.
    try device.flush()
    sb.logEpoch += 1
    sb.generation += 1
    try device.write(sb.slot, sb.encode())
    try device.flush()
    return groups
  }
}
