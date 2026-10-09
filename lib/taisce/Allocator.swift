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

/// Free space as a bitmap, one bit a block (set: in use), kept in memory.
/// On disk there are two bitmaps, written by alternate transaction groups
/// (S1), each with the blocks that changed since it was last written. First
/// fit from a hint, in extents; S3 moves to per-CPU allocation groups with
/// free-extent trees (filesystem.md §2).
///
/// A freed block waits before it's handed out again: held through the
/// group that freed it (committed state still points at it), then deferred
/// through the next, so even if that group's superblock were unreadable and
/// mount fell back a group, nothing it points at has been reused.
public struct Allocator: Sendable {
  public let blockCount: UInt64
  var words: [UInt64]
  /// Blocks freed in the current transaction group: free on disk once it
  /// commits, but not handed out before, since committed state may still
  /// point at them (a crash would find another file's data there).
  var held: [UInt64]
  /// Blocks freed in the previous group, not handed out until this one
  /// commits.
  var deferred: [UInt64]
  /// Blocks allocated in the current group: nothing committed points at
  /// them, so they may be rewritten in place.
  var fresh: [UInt64]
  /// Fresh blocks the intent log now names (S1e): an fsync promised what's
  /// in them, so they're no longer rewritten in place, and freeing them
  /// holds them until the group commits.
  var logged: [UInt64]
  /// Bitmap blocks changed since each on-disk bitmap was last written, a
  /// flag each (no hashed set: tier 0 links without libm, which Set's
  /// sizing uses).
  var dirty: [[Bool]]
  public private(set) var freeCount: UInt64

  static let bitsPerBitmapBlock = UInt64(Layout.blockSize * 8)

  /// Everything free except the first `reserved` blocks (the ring and the
  /// bitmaps) and the last `reservedTail` (the footer ring).
  public init(blockCount: UInt64, reserved: UInt64, reservedTail: UInt64 = 0) {
    self.blockCount = blockCount
    words = [UInt64](repeating: 0, count: Int((blockCount + 63) / 64))
    held = words
    deferred = words
    fresh = words
    logged = words
    let bitmapBlocks = Int((blockCount + Self.bitsPerBitmapBlock - 1) / Self.bitsPerBitmapBlock)
    dirty = [[Bool]](repeating: [Bool](repeating: false, count: bitmapBlocks), count: 2)
    freeCount = blockCount
    markUsed(Extent(start: 0, count: reserved))
    markUsed(Extent(start: blockCount - reservedTail, count: reservedTail))
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
    held = [UInt64](repeating: 0, count: wordCount)
    deferred = held
    fresh = held
    logged = held
    let bitmapBlocks = Int((blockCount + Self.bitsPerBitmapBlock - 1) / Self.bitsPerBitmapBlock)
    dirty = [[Bool]](repeating: [Bool](repeating: false, count: bitmapBlocks), count: 2)
    let tail = blockCount % 64
    if tail != 0 { words[wordCount - 1] |= ~((1 << tail) - 1) }
    var used: UInt64 = 0
    for w in words { used += UInt64(w.nonzeroBitCount) }
    freeCount = blockCount - min(blockCount, used - (tail == 0 ? 0 : 64 - tail))
  }

  public func isUsed(_ block: UInt64) -> Bool { words[Int(block / 64)] & (1 << (block % 64)) != 0 }

  /// Whether `block` may be handed out: free, and not held or deferred.
  func isAvailable(_ block: UInt64) -> Bool {
    let w = Int(block / 64)
    return (words[w] | held[w] | deferred[w]) & (1 << (block % 64)) == 0
  }

  /// Whether `block` was allocated in the current group.
  public func isFresh(_ block: UInt64) -> Bool { fresh[Int(block / 64)] & (1 << (block % 64)) != 0 }

  /// Whether `block` may be rewritten in place: allocated in this group and
  /// not yet promised to an fsync.
  public func isRewritable(_ block: UInt64) -> Bool {
    let w = Int(block / 64), bit: UInt64 = 1 << (block % 64)
    return fresh[w] & bit != 0 && logged[w] & bit == 0
  }

  /// The intent log now names `e`.
  public mutating func pin(_ e: Extent) {
    for b in e.start..<e.end { logged[Int(b / 64)] |= 1 << (b % 64) }
  }

  /// Marks `e` in use (replaying the intent log onto the committed bitmap).
  public mutating func claim(_ e: Extent) { take(e) }

  /// The group committed: what it freed is deferred through the next group,
  /// what the previous group freed becomes available, and fresh blocks are
  /// committed state.
  public mutating func groupCommitted() {
    for i in held.indices {
      deferred[i] = held[i]
      held[i] = 0
      fresh[i] = 0
      logged[i] = 0
    }
  }

  mutating func set(_ block: UInt64, used: Bool) {
    let w = Int(block / 64), bit: UInt64 = 1 << (block % 64)
    guard (words[w] & bit != 0) != used else { return }
    if used { words[w] |= bit; freeCount -= 1 } else { words[w] &= ~bit; freeCount += 1 }
    let index = Int(block / Self.bitsPerBitmapBlock)
    dirty[0][index] = true
    dirty[1][index] = true
  }

  mutating func markUsed(_ e: Extent) { for b in e.start..<e.end { set(b, used: true) } }

  mutating func take(_ e: Extent) {
    for b in e.start..<e.end {
      set(b, used: true)
      fresh[Int(b / 64)] |= 1 << (b % 64)
    }
  }

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
      // Skip whole unavailable words quickly.
      if b % 64 == 0, words[Int(b / 64)] | held[Int(b / 64)] | deferred[Int(b / 64)] == ~0 {
        let step = min(64, blockCount - b)
        scanned += step
        b = b + step == blockCount ? 0 : b + step
        continue
      }
      if !isAvailable(b) {
        scanned += 1
        b = b + 1 == blockCount ? 0 : b + 1
        continue
      }
      var run: UInt64 = 0
      while run < needed, b + run < blockCount, isAvailable(b + run) { run += 1 }
      let e = Extent(start: b, count: run)
      take(e)
      out.append(e)
      needed -= run
      scanned += run
      b = b + run == blockCount ? 0 : b + run
    }
    guard needed == 0 else {
      // Held blocks made the free count promise too much: take nothing.
      for e in out { release(e) }
      throw .noSpace
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
        if !isAvailable(b) {
          b += 1
          continue
        }
        var run: UInt64 = 0
        while run < count, isAvailable(b + run) { run += 1 }
        if run == count {
          let e = Extent(start: b, count: count)
          take(e)
          return e
        }
        b += run + 1
      }
      start = 0
    }
    throw .noSpace
  }

  /// Frees `e`. Blocks allocated in this group are available again at
  /// once; others are held until the group commits.
  public mutating func free(_ e: Extent) {
    for b in e.start..<e.end {
      set(b, used: false)
      let w = Int(b / 64), bit: UInt64 = 1 << (b % 64)
      if fresh[w] & bit != 0 && logged[w] & bit == 0 { fresh[w] &= ~bit } else { held[w] |= bit }
    }
  }

  /// Undoes an allocation made in this group.
  mutating func release(_ e: Extent) {
    for b in e.start..<e.end {
      set(b, used: false)
      fresh[Int(b / 64)] &= ~(1 << (b % 64))
    }
  }

  /// The blocks of on-disk bitmap `region` (0 or 1) that changed since it
  /// was last written, as (index within the bitmap, contents); forgets that
  /// they changed for that region.
  public mutating func dirtyBlocks(region: Int) -> [(index: UInt64, bytes: [UInt8])] {
    let wordsPerBlock = Layout.blockSize / 8
    let out = dirty[region].indices.filter { dirty[region][$0] }.map { i -> (index: UInt64, bytes: [UInt8]) in
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
    for i in dirty[region].indices { dirty[region][i] = false }
    return out
  }

  /// BLAKE3-128 of the whole bitmap as it would be written.
  public func checksum() -> Checksum {
    var all: [UInt8] = []
    all.reserveCapacity(words.count * 8)
    for (i, word) in words.enumerated() {
      var w = word
      if i == words.count - 1, blockCount % 64 != 0 { w &= (1 << (blockCount % 64)) - 1 }  // the tail as stored
      for k in 0..<8 { all.append(UInt8(truncatingIfNeeded: w >> (8 * UInt64(k)))) }
    }
    return Checksum(of: all)
  }

  /// Every block of the bitmap, as (index, contents): for formatting both
  /// regions.
  public mutating func allBlocks() -> [(index: UInt64, bytes: [UInt8])] {
    for r in 0..<2 { for i in dirty[r].indices { dirty[r][i] = true } }
    _ = dirtyBlocks(region: 1)
    return dirtyBlocks(region: 0)
  }
}
