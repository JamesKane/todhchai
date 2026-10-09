// SPDX-License-Identifier: BSD-3-Clause

/// The volume, and the B+tree nodes in memory: a direct-mapped cache of
/// clean nodes (each checked against its pointer's checksum when read), and
/// the nodes changed in this transaction group, until the commit writes
/// them. Every tree on the volume shares one store.
///
/// Copy-on-write (S1): a committed node is never changed where it is.
/// `update` gives it a new block (unless it was allocated in this group,
/// which nothing committed points at) and holds the old one until the
/// commit.
public struct Store<Device: BlockDevice>: ~Copyable {
  public var volume: Volume<Device>
  var cache: [CachedNode?]
  /// Changed nodes, sorted by block. No hashed collections in tier 0.
  var dirty: [CachedNode] = []

  struct CachedNode {
    var block: UInt64
    var node: Node
  }

  public init(_ volume: consuming Volume<Device>, cacheNodes: Int = 512) {
    self.volume = volume
    cache = [CachedNode?](repeating: nil, count: max(1, cacheNodes))
  }

  func slot(_ block: UInt64) -> Int { Int((block / UInt64(Layout.nodeBlocks)) % UInt64(cache.count)) }

  func dirtyIndex(_ block: UInt64) -> (found: Bool, at: Int) {
    var lo = 0, hi = dirty.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if dirty[mid].block < block { lo = mid + 1 } else { hi = mid }
    }
    return (lo < dirty.count && dirty[lo].block == block, lo)
  }

  /// The node `pointer` points at. Read from the device, its bytes must
  /// have the pointer's checksum (`.corrupt(.checksum)` otherwise).
  public mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node {
    let block = pointer.block
    let d = dirtyIndex(block)
    if d.found { return dirty[d.at].node }
    let s = slot(block)
    if let c = cache[s], c.block == block { return c.node }
    let bytes = try volume.device.read(block, count: Layout.nodeBlocks)
    guard Checksum(of: bytes) == pointer.checksum else { throw .corrupt(.checksum(block)) }
    let node = try Node.decode(bytes)
    cache[s] = CachedNode(block: block, node: node)
    return node
  }

  /// Gives `node` a block for this group: `block` itself if it was
  /// allocated in this group, else a new one (the old is held until the
  /// commit). Returns the block it's now at.
  public mutating func update(_ block: UInt64, _ node: Node) throws(TaisceError) -> UInt64 {
    if volume.allocator.isFresh(block) {
      put(block, node)
      return block
    }
    let moved = try allocateNode(near: block)
    put(moved, node)
    freeNode(block)
    return moved
  }

  /// Replaces the node at `block`, in memory until `writeDirty`.
  public mutating func put(_ block: UInt64, _ node: Node) {
    let d = dirtyIndex(block)
    if d.found { dirty[d.at].node = node } else { dirty.insert(CachedNode(block: block, node: node), at: d.at) }
    let s = slot(block)
    if let c = cache[s], c.block == block { cache[s] = nil }
  }

  /// Blocks for a new node, near `hint`.
  public mutating func allocateNode(near hint: UInt64 = 0) throws(TaisceError) -> UInt64 {
    try volume.allocator.allocateContiguous(UInt64(Layout.nodeBlocks), near: hint).start
  }

  /// Frees a node's blocks, and forgets it.
  public mutating func freeNode(_ block: UInt64) {
    let d = dirtyIndex(block)
    if d.found { dirty.remove(at: d.at) }
    let s = slot(block)
    if let c = cache[s], c.block == block { cache[s] = nil }
    volume.allocator.free(Extent(start: block, count: UInt64(Layout.nodeBlocks)))
  }

  public var dirtyCount: Int { dirty.count }

  /// After a commit wrote the changed nodes: keeps them as clean.
  public mutating func written() {
    for d in dirty { cache[slot(d.block)] = d }
    dirty = []
  }
}
