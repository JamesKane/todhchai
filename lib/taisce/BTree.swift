// SPDX-License-Identifier: BSD-3-Clause

/// A B+tree over byte-string keys in byte order, with byte-string values
/// (filesystem.md §3–4). Its nodes live in a Store; the tree itself is
/// just its root. The file system tree, the index forest and the change
/// journal are each one, with keys encoded so byte order is their order.
///
/// Nodes split and merge by encoded size: a node holds what fits in 16 KiB,
/// and one under a quarter full borrows from or merges with a sibling.
public struct BTree: Equatable, Sendable {
  /// The root node's block, or 0 for an empty tree.
  public var root: UInt64

  public init(root: UInt64 = 0) { self.root = root }

  public static let maxKey = 1024
  public static let maxValue = 3072
  static let minFill = Node.bytes / 4

  // MARK: Reading

  public func get<D>(_ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> [UInt8]? {
    guard root != 0 else { return nil }
    var block = root
    while true {
      let n = try store.node(block)
      if n.isLeaf {
        let i = n.lowerBound(key)
        return i < n.keys.count && n.keys[i] == key ? n.values[i] : nil
      }
      block = n.children[n.childIndex(key)]
    }
  }

  /// The entries with `from ≤ key < to` (to the end if `to` is nil), in
  /// order, at most `limit`.
  public func scan<D>(from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max, _ store: inout Store<D>)
    throws(TaisceError) -> [(key: [UInt8], value: [UInt8])]
  {
    var out: [(key: [UInt8], value: [UInt8])] = []
    guard root != 0, limit > 0 else { return out }
    try collect(root, from, to, limit, &out, &store)
    return out
  }

  /// Visits the subtree in order, from the child covering `from`.
  func collect<D>(_ block: UInt64, _ from: [UInt8], _ to: [UInt8]?, _ limit: Int,
                  _ out: inout [(key: [UInt8], value: [UInt8])], _ store: inout Store<D>) throws(TaisceError) {
    let n = try store.node(block)
    if n.isLeaf {
      var i = n.lowerBound(from)
      while i < n.keys.count, out.count < limit {
        if let to, !n.keys[i].lexicographicallyPrecedes(to) { return }
        out.append((n.keys[i], n.values[i]))
        i += 1
      }
      return
    }
    var c = n.childIndex(from)
    while c < n.children.count, out.count < limit {
      // A child whose lower bound is at or past `to` holds nothing wanted.
      if c > 0, let to, !n.keys[c - 1].lexicographicallyPrecedes(to) { return }
      try collect(n.children[c], from, to, limit, &out, &store)
      c += 1
    }
  }

  // MARK: Inserting

  /// Sets `key` to `value`, replacing what was there.
  public mutating func insert<D>(_ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>) throws(TaisceError) {
    guard key.count <= Self.maxKey, value.count <= Self.maxValue else { throw .tooLarge }
    guard root != 0 else {
      var leaf = Node(level: 0)
      leaf.keys = [key]
      leaf.values = [value]
      root = try store.allocateNode(near: store.volume.superblock.layout.dataStart)
      store.put(root, leaf)
      return
    }
    if let (separator, right) = try insert(root, key, value, &store) {
      let old = try store.node(root)
      var top = Node(level: old.level + 1)
      top.keys = [separator]
      top.children = [root, right]
      let block = try store.allocateNode(near: root)
      store.put(block, top)
      root = block
    }
  }

  /// Inserts into the subtree at `block`; if it split, the separator and
  /// the new right node.
  func insert<D>(_ block: UInt64, _ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>)
    throws(TaisceError) -> (separator: [UInt8], right: UInt64)?
  {
    var n = try store.node(block)
    if n.isLeaf {
      let i = n.lowerBound(key)
      if i < n.keys.count && n.keys[i] == key {
        n.values[i] = value
      } else {
        n.keys.insert(key, at: i)
        n.values.insert(value, at: i)
      }
    } else {
      let c = n.childIndex(key)
      guard let (separator, right) = try insert(n.children[c], key, value, &store) else { return nil }
      n.keys.insert(separator, at: c)
      n.children.insert(right, at: c + 1)
    }
    guard n.size > Node.bytes else {
      store.put(block, n)
      return nil
    }
    let (left, separator, right) = split(n)
    let rightBlock = try store.allocateNode(near: block)
    store.put(block, left)
    store.put(rightBlock, right)
    return (separator, rightBlock)
  }

  /// Splits an overfull node near the middle of its bytes.
  func split(_ n: Node) -> (Node, [UInt8], Node) {
    var left = Node(level: n.level), right = Node(level: n.level)
    let half = (n.size - Node.headerSize) / 2
    var used = 0, at = 0
    // A leaf's right half needs a key; an internal one's needs a key after
    // the one that moves up.
    let last = n.isLeaf ? n.keys.count - 1 : n.keys.count - 2
    while at < last {
      let cell = n.isLeaf ? Node.leafCell(n.keys[at], n.values[at]) : Node.internalCell(n.keys[at])
      if used + cell > half && at > 0 { break }
      used += cell
      at += 1
    }
    if n.isLeaf {
      left.keys = Array(n.keys[..<at])
      left.values = Array(n.values[..<at])
      right.keys = Array(n.keys[at...])
      right.values = Array(n.values[at...])
      return (left, right.keys[0], right)
    }
    // The middle key moves up; the children split around it.
    left.keys = Array(n.keys[..<at])
    left.children = Array(n.children[...at])
    right.keys = Array(n.keys[(at + 1)...])
    right.children = Array(n.children[(at + 1)...])
    return (left, n.keys[at], right)
  }

  // MARK: Deleting

  /// Removes `key`; false if it wasn't there.
  @discardableResult
  public mutating func delete<D>(_ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> Bool {
    guard root != 0 else { return false }
    let found = try delete(root, key, &store)
    // Shrink from the top: an empty leaf root empties the tree, and an
    // internal root with one child hands over to it.
    let r = try store.node(root)
    if r.keys.isEmpty {
      store.freeNode(root)
      root = r.isLeaf ? 0 : r.children[0]
    }
    return found
  }

  /// Deletes from the subtree at `block`, rebalancing children that fall
  /// under a quarter full. Whether the key was there.
  func delete<D>(_ block: UInt64, _ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> Bool {
    var n = try store.node(block)
    if n.isLeaf {
      let i = n.lowerBound(key)
      guard i < n.keys.count, n.keys[i] == key else { return false }
      n.keys.remove(at: i)
      n.values.remove(at: i)
      store.put(block, n)
      return true
    }
    let c = n.childIndex(key)
    guard try delete(n.children[c], key, &store) else { return false }
    let child = try store.node(n.children[c])
    if child.size < Self.minFill && n.children.count > 1 {
      try rebalance(&n, c, &store)
      store.put(block, n)
    }
    return true
  }

  /// Merges child `c` with a sibling, or shares entries with it.
  func rebalance<D>(_ parent: inout Node, _ c: Int, _ store: inout Store<D>) throws(TaisceError) {
    let l = c + 1 < parent.children.count ? c : c - 1  // the pair (l, l + 1)
    let leftBlock = parent.children[l], rightBlock = parent.children[l + 1]
    let left = try store.node(leftBlock), right = try store.node(rightBlock)
    // Everything in one node, in order (an internal pair pulls the separator down).
    var all = Node(level: left.level)
    all.keys = left.keys
    all.values = left.values
    all.children = left.children
    if !left.isLeaf { all.keys.append(parent.keys[l]) }
    all.keys += right.keys
    all.values += right.values
    all.children += right.children
    if all.size <= Node.bytes {
      store.put(leftBlock, all)
      store.freeNode(rightBlock)
      parent.keys.remove(at: l)
      parent.children.remove(at: l + 1)
    } else {
      let (newLeft, separator, newRight) = split(all)
      store.put(leftBlock, newLeft)
      store.put(rightBlock, newRight)
      parent.keys[l] = separator
    }
  }

  // MARK: Checking

  public struct Stats: Equatable, Sendable {
    public var entries = 0
    public var nodes = 0
    public var depth = 0
  }

  /// Checks every invariant: order, bounds, even depth, fill, and that
  /// every node's blocks are allocated. For tests and fsck.
  public func check<D>(_ store: inout Store<D>) throws(TaisceError) -> Stats {
    var stats = Stats()
    guard root != 0 else { return stats }
    var leafDepth: Int? = nil
    try check(root, lower: nil, upper: nil, depth: 1, isRoot: true, &leafDepth, &stats, &store)
    stats.depth = leafDepth ?? 0
    return stats
  }

  func check<D>(_ block: UInt64, lower: [UInt8]?, upper: [UInt8]?, depth: Int, isRoot: Bool, _ leafDepth: inout Int?,
                _ stats: inout Stats, _ store: inout Store<D>) throws(TaisceError) {
    for b in block..<(block + UInt64(Layout.nodeBlocks)) where !store.volume.allocator.isUsed(b) {
      throw .corrupt(.tree(.blockNotAllocated))
    }
    let n = try store.node(block)
    stats.nodes += 1
    guard n.size <= Node.bytes else { throw .corrupt(.tree(.overfull)) }
    if !isRoot && n.size < Self.minFill && n.keys.count > 1 {
      // A node with one big entry can't be fuller; otherwise it must be.
      throw .corrupt(.tree(.underfull))
    }
    for i in n.keys.indices {
      if i > 0, !n.keys[i - 1].lexicographicallyPrecedes(n.keys[i]) { throw .corrupt(.tree(.keysOutOfOrder)) }
      if let lower, n.keys[i].lexicographicallyPrecedes(lower) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
      if let upper, !n.keys[i].lexicographicallyPrecedes(upper) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
    }
    if n.isLeaf {
      if let d = leafDepth, d != depth { throw .corrupt(.tree(.uneven)) }
      leafDepth = depth
      stats.entries += n.keys.count
      return
    }
    guard n.children.count == n.keys.count + 1, !n.keys.isEmpty else { throw .corrupt(.tree(.childCount)) }
    for c in n.children.indices {
      try check(n.children[c], lower: c == 0 ? lower : n.keys[c - 1], upper: c == n.keys.count ? upper : n.keys[c],
                depth: depth + 1, isRoot: false, &leafDepth, &stats, &store)
    }
  }
}
