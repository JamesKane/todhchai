// SPDX-License-Identifier: BSD-3-Clause

/// A change to apply to a value without reading it first: gefs's blind
/// deltas (filesystem.md §4), such as "set mtime and size" or "bump the
/// version".
public enum Delta: Equatable, Sendable {
  /// Overwrites bytes at `offset`.
  case put(offset: Int, bytes: [UInt8])
  /// Adds to the little-endian u64 at `offset`, wrapping.
  case add(offset: Int, value: UInt64)
}

/// One step of a transaction.
public enum Message: Equatable, Sendable {
  case insert(tree: UInt64, key: [UInt8], value: [UInt8])
  case delete(tree: UInt64, key: [UInt8])
  case delta(tree: UInt64, key: [UInt8], Delta)

  var tree: UInt64 {
    switch self {
    case .insert(let t, _, _), .delete(let t, _), .delta(let t, _, _): t
    }
  }
  var key: [UInt8] {
    switch self {
    case .insert(_, let k, _), .delete(_, let k), .delta(_, let k, _): k
    }
  }
}

/// Taisce's storage engine: trees by ID, changed by atomic batches of
/// messages, made durable a transaction group at a time through the log.
/// Callers never see nodes or blocks, so S1 can replace the commit layer
/// beneath this API (filesystem.md §2, §4).
public struct Engine<Device: BlockDevice>: ~Copyable {
  public var store: Store<Device>
  /// Every tree's root, by ID, sorted; `changed` marks those to record in
  /// the catalog at the next commit.
  var trees: [(id: UInt64, tree: BTree, changed: Bool)] = []
  var catalog: BTree
  /// The transaction group being built: one past the last committed.
  public private(set) var txg: UInt64
  /// File data was written since the last commit: it needs a barrier before
  /// the log (ordered data, as ext4's default mode).
  public var dataWritten = false
  public var nextInode: UInt64

  /// A new volume on `device`.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64)
    throws(TaisceError) -> Engine
  {
    let volume = try Volume.format(device, label: label, uuid: uuid, now: now)
    return try mount(volume.device)
  }

  /// Mounts the volume on `device`: its newest valid superblock is the
  /// state (there's nothing to replay).
  public static func mount(_ device: consuming Device) throws(TaisceError) -> Engine {
    try Engine(Store(try Volume.open(device)))
  }

  init(_ store: consuming Store<Device>) throws(TaisceError) {
    self.store = store
    let sb = self.store.volume.superblock
    catalog = BTree(root: sb.catalogRoot)
    nextInode = sb.nextInode
    txg = sb.txg + 1
    for (key, value) in try catalog.scan(from: [], &self.store) {
      guard key.count == 8, value.count == NodePointer.size else { throw .corrupt(.catalog) }
      trees.append((Self.bigEndianID(key), BTree(root: NodePointer.get(value, at: 0)), false))
    }
  }

  static func idKey(_ id: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: id >> (56 - 8 * $0)) } }
  static func bigEndianID(_ key: [UInt8]) -> UInt64 { key.reduce(0) { $0 << 8 | UInt64($1) } }

  func treeIndex(_ id: UInt64) -> (found: Bool, at: Int) {
    var lo = 0, hi = trees.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if trees[mid].id < id { lo = mid + 1 } else { hi = mid }
    }
    return (lo < trees.count && trees[lo].id == id, lo)
  }

  /// The IDs of every tree with entries.
  public var treeIDs: [UInt64] { trees.filter { !$0.tree.isEmpty }.map { $0.id } }

  // MARK: Reading

  public mutating func get(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> [UInt8]? {
    let t = treeIndex(tree)
    guard t.found else { return nil }
    return try trees[t.at].tree.get(key, &store)
  }

  /// The last entry of `tree` whose key is at most `key`.
  public mutating func floor(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> (key: [UInt8], value: [UInt8])? {
    let t = treeIndex(tree)
    guard t.found else { return nil }
    return try trees[t.at].tree.floor(key, &store)
  }

  public mutating func scan(_ tree: UInt64, from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max)
    throws(TaisceError) -> [(key: [UInt8], value: [UInt8])]
  {
    let t = treeIndex(tree)
    guard t.found else { return [] }
    return try trees[t.at].tree.scan(from: from, to: to, limit: limit, &store)
  }

  // MARK: Transactions

  /// Applies `batch` atomically: all of it, or (if one message fails)
  /// none. The messages are sorted by tree and key, keeping their order
  /// within a key. Durable after the next `commitGroup`.
  public mutating func apply(_ batch: [Message]) throws(TaisceError) {
    let ordered = batch.indices.sorted { a, b in
      let x = batch[a], y = batch[b]
      if x.tree != y.tree { return x.tree < y.tree }
      if x.key != y.key { return x.key.lexicographicallyPrecedes(y.key) }
      return a < b
    }.map { batch[$0] }
    // What each changed key held before, to undo with.
    var undo: [(tree: UInt64, key: [UInt8], value: [UInt8]?)] = []
    do throws(TaisceError) {
      for m in ordered {
        let before = try get(m.tree, m.key)
        undo.append((m.tree, m.key, before))
        switch m {
        case .insert(let tree, let key, let value):
          try set(tree, key, value)
        case .delete(let tree, let key):
          if before != nil { try remove(tree, key) }
        case .delta(let tree, let key, let delta):
          guard var value = before else { throw .missingKey }
          try Self.apply(delta, to: &value)
          try set(tree, key, value)
        }
      }
    } catch {
      for u in undo.reversed() {
        if let v = u.value { try? set(u.tree, u.key, v) } else { try? remove(u.tree, u.key) }
      }
      throw error
    }
  }

  static func apply(_ delta: Delta, to value: inout [UInt8]) throws(TaisceError) {
    switch delta {
    case .put(let offset, let bytes):
      guard offset >= 0, offset + bytes.count <= value.count else { throw .badDelta }
      value.put(bytes: bytes, at: offset)
    case .add(let offset, let n):
      guard offset >= 0, offset + 8 <= value.count else { throw .badDelta }
      value.put(value.get(UInt64.self, at: offset) &+ n, at: offset)
    }
  }

  mutating func set(_ id: UInt64, _ key: [UInt8], _ value: [UInt8]) throws(TaisceError) {
    var t = treeIndex(id)
    if !t.found {
      trees.insert((id, BTree(), true), at: t.at)
      t.found = true
    }
    var tree = trees[t.at].tree
    try tree.insert(key, value, &store)
    if tree != trees[t.at].tree { trees[t.at] = (id, tree, true) }
  }

  mutating func remove(_ id: UInt64, _ key: [UInt8]) throws(TaisceError) {
    let t = treeIndex(id)
    guard t.found else { return }
    var tree = trees[t.at].tree
    try tree.delete(key, &store)
    if tree != trees[t.at].tree { trees[t.at] = (id, tree, true) }
  }

  // MARK: Committing

  /// Blocks the next commit will write (an estimate: the catalog may add a few).
  public var pendingBlocks: Int { store.dirtyCount * Layout.nodeBlocks }

  /// Makes every applied transaction durable, by superblock flip. Each
  /// changed tree is written bottom-up to its new blocks (its nodes taking
  /// checksums), its root pointer goes into the catalog, and the catalog is
  /// written last; then the volume writes the bitmap, a barrier, the
  /// superblock naming the catalog's root, and a barrier. File data written
  /// for the group is made durable by that first barrier too.
  public mutating func commitGroup() throws(TaisceError) {
    var written: [(block: UInt64, bytes: [UInt8])] = []
    for i in trees.indices where trees[i].changed {
      try trees[i].tree.write(&store, txg: txg, &written)
      let key = Self.idKey(trees[i].id)
      if trees[i].tree.isEmpty {
        try catalog.delete(key, &store)
      } else {
        try catalog.insert(key, trees[i].tree.root.encode(), &store)
      }
      trees[i].changed = false
    }
    try catalog.write(&store, txg: txg, &written)
    let sb = store.volume.superblock
    guard !written.isEmpty || dataWritten || catalog.root != sb.catalogRoot || nextInode != sb.nextInode else {
      store.volume.allocator.groupCommitted()
      return
    }
    for (block, bytes) in written { try store.volume.device.write(block, bytes) }
    store.written()
    let root = catalog.root, inode = nextInode
    try store.volume.commit { sb in
      sb.catalogRoot = root
      sb.nextInode = inode
    }
    dataWritten = false
    txg = store.volume.superblock.txg + 1
  }

  /// Every block metadata lives in: each node's four blocks, in every tree
  /// and the catalog (scrub reads them all; the corruption tests flip them).
  public mutating func nodeBlocks() throws(TaisceError) -> [UInt64] {
    var firsts = try catalog.nodeBlocks(&store)
    for t in trees { firsts += try t.tree.nodeBlocks(&store) }
    return firsts.flatMap { b in (0..<UInt64(Layout.nodeBlocks)).map { b + $0 } }
  }

  /// Every tree's invariants, and that the blocks in use are exactly the
  /// reserved ones, the trees' nodes and `dataBlocks` (the file system's
  /// extents): nothing leaked, nothing shared.
  public mutating func check(dataBlocks: UInt64 = 0) throws(TaisceError) -> (entries: Int, nodes: Int) {
    var entries = 0, nodes = try catalog.check(&store).nodes
    for t in trees {
      let s = try t.tree.check(&store)
      entries += s.entries
      nodes += s.nodes
    }
    let a = store.volume.allocator
    let used = a.blockCount - a.freeCount
    guard used == store.volume.superblock.layout.reserved + UInt64(nodes * Layout.nodeBlocks) + dataBlocks else {
      throw .corrupt(.leakedBlocks)
    }
    return (entries, nodes)
  }
}
