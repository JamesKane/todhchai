// SPDX-License-Identifier: BSD-3-Clause

/// The volume, and the B+tree nodes in memory: a direct-mapped cache of
/// clean nodes, and the nodes changed since the last `writeDirty`, kept
/// until they're written (S0c logs them first). Every tree on the volume
/// shares one store.
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

  /// The node at `block`.
  public mutating func node(_ block: UInt64) throws(TaisceError) -> Node {
    let d = dirtyIndex(block)
    if d.found { return dirty[d.at].node }
    let s = slot(block)
    if let c = cache[s], c.block == block { return c.node }
    let node = try Node.decode(volume.device.read(block, count: Layout.nodeBlocks))
    cache[s] = CachedNode(block: block, node: node)
    return node
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

  /// The changed nodes, as (block, encoded), in block order.
  public var dirtyNodes: [(block: UInt64, bytes: [UInt8])] { dirty.map { ($0.block, $0.node.encode()) } }

  public var dirtyCount: Int { dirty.count }

  /// Writes the changed nodes in place and keeps them as clean.
  public mutating func writeDirty() throws(TaisceError) {
    for d in dirty {
      try volume.device.write(d.block, d.node.encode())
      cache[slot(d.block)] = d
    }
    dirty = []
  }
}
