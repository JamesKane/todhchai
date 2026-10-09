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
  var logAt: UInt64
  var logSeq: UInt64 = 0
  public private(set) var txg: UInt64 = 1
  public var nextInode: UInt64

  /// A new volume on `device`.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64,
                            logBlocks: UInt64? = nil) throws(TaisceError) -> Engine {
    let volume = try Volume.format(device, label: label, uuid: uuid, now: now, logBlocks: logBlocks)
    return try mount(volume.device)
  }

  /// Mounts the volume on `device`, replaying its log.
  public static func mount(_ device: consuming Device) throws(TaisceError) -> Engine {
    var d = device
    try Log.replay(&d)
    let volume = try Volume.open(d)
    return try Engine(Store(volume))
  }

  init(_ store: consuming Store<Device>) throws(TaisceError) {
    self.store = store
    let sb = self.store.volume.superblock
    catalog = BTree(root: sb.catalogRoot)
    nextInode = sb.nextInode
    logAt = sb.layout.logStart
    for (key, value) in try catalog.scan(from: [], &self.store) {
      guard key.count == 8, value.count == 8 else { throw .corrupt(.catalog) }
      trees.append((Self.bigEndianID(key), BTree(root: value.get(UInt64.self, at: 0)), false))
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
  public var treeIDs: [UInt64] { trees.filter { $0.tree.root != 0 }.map(\.id) }

  // MARK: Reading

  public mutating func get(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> [UInt8]? {
    let t = treeIndex(tree)
    guard t.found else { return nil }
    return try trees[t.at].tree.get(key, &store)
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

  /// Blocks the next commit will log (an estimate: the catalog may add a few).
  public var pendingBlocks: Int { store.dirtyCount * Layout.nodeBlocks }

  /// Makes every applied transaction durable: the group's changed blocks go
  /// to the log, a barrier commits them, and they're written in place.
  public mutating func commitGroup() throws(TaisceError) {
    // Record changed roots in the catalog (which may change its own root).
    for i in trees.indices where trees[i].changed {
      let key = Self.idKey(trees[i].id)
      if trees[i].tree.root == 0 {
        try catalog.delete(key, &store)
      } else {
        var v = [UInt8](repeating: 0, count: 8)
        v.put(trees[i].tree.root, at: 0)
        try catalog.insert(key, v, &store)
      }
      trees[i].changed = false
    }
    var targets: [UInt64] = []
    var blocks: [UInt8] = []
    for (block, bytes) in store.dirtyNodes {
      for i in 0..<Layout.nodeBlocks { targets.append(block + UInt64(i)) }
      blocks += bytes
    }
    let layout = store.volume.superblock.layout
    for (index, bytes) in store.volume.allocator.dirtyBlocks() {
      targets.append(layout.bitmapStart + index)
      blocks += bytes
    }
    guard !targets.isEmpty || catalog.root != store.volume.superblock.catalogRoot else { return }

    // The records: as many as the blocks need, at least one.
    let records = max(1, (targets.count + Log.maxBlocks - 1) / Log.maxBlocks)
    let logBlocks = UInt64(records + targets.count)
    let end = layout.logStart + layout.logBlocks
    guard logBlocks <= layout.logBlocks else { throw .tooLarge }
    if logAt + logBlocks > end { try checkpoint() }
    var image: [UInt8] = []
    for r in 0..<records {
      let range = (r * Log.maxBlocks)..<min(targets.count, (r + 1) * Log.maxBlocks)
      let record = Log.Record(
        last: r == records - 1, epoch: store.volume.superblock.logEpoch, seq: logSeq, txg: txg,
        catalogRoot: catalog.root, nextInode: nextInode, targets: Array(targets[range]),
        blocks: Array(blocks[(range.lowerBound * Layout.blockSize)..<(range.upperBound * Layout.blockSize)]))
      image += record.encode()
      logSeq += 1
    }
    try store.volume.device.write(logAt, image)
    try store.volume.device.flush()  // the commit point
    logAt += logBlocks
    // In place; durable by the next checkpoint's barrier.
    try store.writeDirty()
    for (i, target) in targets.enumerated() where target >= layout.bitmapStart && target < layout.dataStart {
      let start = i * Layout.blockSize
      try store.volume.device.write(target, Array(blocks[start..<(start + Layout.blockSize)]))
    }
    txg += 1
  }

  /// Makes the in-place writes durable and starts the log over.
  mutating func checkpoint() throws(TaisceError) {
    let root = catalog.root, inode = nextInode
    try store.volume.commit { sb in
      sb.catalogRoot = root
      sb.nextInode = inode
      sb.logEpoch += 1
    }
    logAt = store.volume.superblock.layout.logStart
    logSeq = 0
  }

  /// Every tree's invariants, and that the blocks in use are exactly the
  /// reserved ones and the trees' nodes: nothing leaked, nothing shared.
  public mutating func check() throws(TaisceError) -> (entries: Int, nodes: Int) {
    var entries = 0, nodes = try catalog.check(&store).nodes
    for t in trees {
      let s = try t.tree.check(&store)
      entries += s.entries
      nodes += s.nodes
    }
    let a = store.volume.allocator
    let used = a.blockCount - a.freeCount
    guard used == store.volume.superblock.layout.dataStart + UInt64(nodes * Layout.nodeBlocks) else {
      throw .corrupt(.leakedBlocks)
    }
    return (entries, nodes)
  }
}
