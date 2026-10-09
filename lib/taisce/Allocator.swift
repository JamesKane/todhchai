// SPDX-License-Identifier: BSD-3-Clause

/// A run of blocks.
public struct Extent: Equatable, Hashable, Sendable {
  public var start: UInt64
  public var count: UInt64
  public init(start: UInt64, count: UInt64) {
    self.start = start
    self.count = count
  }
  public var end: UInt64 { start + count }
}

/// Free space as a bitmap, one bit a block (set: in use), kept in memory
/// and written back by the blocks that changed. S0's allocator: first fit
/// from a hint, in extents. S3 moves to per-CPU allocation groups with
/// free-extent trees (filesystem.md §2).
public struct Allocator: Sendable {
  public let blockCount: UInt64
  var words: [UInt64]
  /// Bitmap blocks changed since the last `dirtyBlocks()`, a flag each
  /// (no hashed set: tier 0 links without libm, which Set's sizing uses).
  var dirty: [Bool]
  public private(set) var freeCount: UInt64

  static let bitsPerBitmapBlock = UInt64(Layout.blockSize * 8)

  /// Everything free except blocks below `reserved` (superblocks, log,
  /// bitmap).
  public init(blockCount: UInt64, reserved: UInt64) {
    self.blockCount = blockCount
    words = [UInt64](repeating: 0, count: Int((blockCount + 63) / 64))
    dirty = [Bool](repeating: false, count: Int((blockCount + Self.bitsPerBitmapBlock - 1) / Self.bitsPerBitmapBlock))
    freeCount = blockCount
    markUsed(Extent(start: 0, count: reserved))
    // Bits past the end are in use, so they're never handed out.
    let tail = blockCount % 64
    if tail != 0 { words[words.count - 1] |= ~((1 << tail) - 1) }
  }

  /// From the bitmap's blocks, as stored.
  public init(blockCount: UInt64, bitmap: [UInt8]) throws(TaisceError) {
    let wordCount = Int((blockCount + 63) / 64)
    guard bitmap.count >= wordCount * 8 else { throw .corrupt(.bitmapSize) }
    self.blockCount = blockCount
    words = (0..<wordCount).map { bitmap.get(UInt64.self, at: $0 * 8) }
    dirty = [Bool](repeating: false, count: Int((blockCount + Self.bitsPerBitmapBlock - 1) / Self.bitsPerBitmapBlock))
    let tail = blockCount % 64
    if tail != 0 { words[wordCount - 1] |= ~((1 << tail) - 1) }
    var used: UInt64 = 0
    for w in words { used += UInt64(w.nonzeroBitCount) }
    freeCount = blockCount - min(blockCount, used - (tail == 0 ? 0 : 64 - tail))
  }

  public func isUsed(_ block: UInt64) -> Bool { words[Int(block / 64)] & (1 << (block % 64)) != 0 }

  mutating func set(_ block: UInt64, used: Bool) {
    let w = Int(block / 64), bit: UInt64 = 1 << (block % 64)
    guard (words[w] & bit != 0) != used else { return }
    if used { words[w] |= bit; freeCount -= 1 } else { words[w] &= ~bit; freeCount += 1 }
    dirty[Int(block / Self.bitsPerBitmapBlock)] = true
  }

  mutating func markUsed(_ e: Extent) { for b in e.start..<e.end { set(b, used: true) } }

  /// `count` blocks, in as few extents as first fit from `near` gives;
  /// none are taken if there isn't room for all of them.
  public mutating func allocate(_ count: UInt64, near: UInt64 = 0) throws(TaisceError) -> [Extent] {
    guard count > 0 else { return [] }
    guard count <= freeCount else { throw .noSpace }
    var out: [Extent] = []
    var needed = count
    var b = near < blockCount ? near : 0
    var scanned: UInt64 = 0
    while needed > 0 && scanned < blockCount {
      // Skip whole used words quickly.
      if b % 64 == 0, words[Int(b / 64)] == ~0 {
        let step = min(64, blockCount - b)
        scanned += step
        b = b + step == blockCount ? 0 : b + step
        continue
      }
      if isUsed(b) {
        scanned += 1
        b = b + 1 == blockCount ? 0 : b + 1
        continue
      }
      var run: UInt64 = 0
      while run < needed, b + run < blockCount, !isUsed(b + run) { run += 1 }
      let e = Extent(start: b, count: run)
      markUsed(e)
      out.append(e)
      needed -= run
      scanned += run
      b = b + run == blockCount ? 0 : b + run
    }
    return out
  }

  /// `count` contiguous blocks (B+tree nodes, the log), or noSpace.
  public mutating func allocateContiguous(_ count: UInt64, near: UInt64 = 0) throws(TaisceError) -> Extent {
    guard count > 0, count <= freeCount else { throw .noSpace }
    var start = near < blockCount ? near : 0
    for _ in 0..<2 {  // from the hint to the end, then from the start
      var b = start
      while b + count <= blockCount {
        if isUsed(b) {
          b += 1
          continue
        }
        var run: UInt64 = 0
        while run < count, !isUsed(b + run) { run += 1 }
        if run == count {
          let e = Extent(start: b, count: count)
          markUsed(e)
          return e
        }
        b += run + 1
      }
      start = 0
    }
    throw .noSpace
  }

  public mutating func free(_ e: Extent) { for b in e.start..<e.end { set(b, used: false) } }

  /// The bitmap's blocks that changed, as (index within the bitmap,
  /// contents), and forgets that they changed.
  public mutating func dirtyBlocks() -> [(index: UInt64, bytes: [UInt8])] {
    let wordsPerBlock = Layout.blockSize / 8
    let out = dirty.indices.filter { dirty[$0] }.map { i -> (index: UInt64, bytes: [UInt8]) in
      let index = UInt64(i)
      var bytes = [UInt8](repeating: 0, count: Layout.blockSize)
      let first = Int(index) * wordsPerBlock
      for i in 0..<wordsPerBlock where first + i < words.count {
        var w = words[first + i]
        if first + i == words.count - 1, blockCount % 64 != 0 { w &= (1 << (blockCount % 64)) - 1 }  // the tail as free
        bytes.put(w, at: i * 8)
      }
      return (index, bytes)
    }
    for i in dirty.indices { dirty[i] = false }
    return out
  }
}
