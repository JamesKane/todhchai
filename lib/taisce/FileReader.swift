// SPDX-License-Identifier: BSD-3-Clause

/// A lock-free reader of a file system (S1f), one per thread. Inside
/// `withSnapshot` it sees one published state, whole, without taking a
/// lock or waiting for the writer. Its caches keep each node and block with
/// the checksum it was verified against, and a hit must match the checksum
/// the snapshot expects, so they never need invalidating when a block is
/// reused.
public struct FileReader<Device: ConcurrentReadable>: ~Copyable, FileReading, Sendable {
  let epochs: EpochManager
  let device: Device
  let slot: Int
  var snapshot: Snapshot?
  var nodes: [VerifiedNode?]
  var blocks: [VerifiedBlock?]

  struct VerifiedNode: Sendable {
    var block: UInt64
    var checksum: Checksum
    var node: Node
  }

  struct VerifiedBlock: Sendable {
    var block: UInt64
    var checksum: Checksum
    var bytes: [UInt8]
  }

  /// A reader of what the writer publishes to `epochs`, on `device` (a copy
  /// of the writer's); nil if every reader slot is taken.
  init?(epochs: EpochManager, device: Device, cacheNodes: Int, cacheBlocks: Int) {
    guard let slot = epochs.register() else { return nil }
    self.epochs = epochs
    self.device = device
    self.slot = slot
    nodes = [VerifiedNode?](repeating: nil, count: max(1, cacheNodes))
    blocks = [VerifiedBlock?](repeating: nil, count: max(1, cacheBlocks))
  }

  deinit { epochs.unregister(slot) }

  /// Runs `body` on the latest published state. Keep it short: the writer
  /// can't reuse what this snapshot sees until it's done.
  public mutating func withSnapshot<T, E: Error>(_ body: (inout FileReader) throws(E) -> T) throws(E) -> T {
    epochs.enter(slot)
    snapshot = epochs.snapshot()
    defer {
      snapshot = nil
      epochs.exit(slot)
    }
    return try body(&self)
  }

  public func root(_ id: UInt64) -> BTree? { snapshot!.root(id) }

  public mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node {
    if let n = snapshot!.dirty.node(pointer.block) { return n }
    let s = Int((pointer.block / UInt64(Layout.nodeBlocks)) % UInt64(nodes.count))
    if let c = nodes[s], c.block == pointer.block, c.checksum == pointer.checksum { return c.node }
    let bytes = try device.readConcurrently(pointer.block, count: Layout.nodeBlocks)
    guard Checksum(of: bytes) == pointer.checksum else { throw .corrupt(.checksum(pointer.block)) }
    let node = try Node.decode(bytes)
    nodes[s] = VerifiedNode(block: pointer.block, checksum: pointer.checksum, node: node)
    return node
  }

  public mutating func dataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>) throws(TaisceError)
    -> [UInt8]
  {
    let bs = Layout.blockSize
    func slot(_ k: Int) -> Int { Int((physical + UInt64(k)) % UInt64(blocks.count)) }
    func hit(_ k: Int, _ sum: Checksum) -> Bool {
      guard let c = blocks[slot(k)] else { return false }
      return c.block == physical + UInt64(k) && c.checksum == sum
    }
    if checksums.enumerated().allSatisfy({ hit($0.offset, $0.element) }) {
      var out: [UInt8] = []
      out.reserveCapacity(checksums.count * bs)
      for k in 0..<checksums.count { out += blocks[slot(k)]!.bytes }
      return out
    }
    let bytes = try device.readConcurrently(physical, count: checksums.count)
    for (k, sum) in checksums.enumerated() {
      let block = Array(bytes[(k * bs)..<((k + 1) * bs)])
      guard Checksum(of: block) == sum else { throw .corrupt(.checksum(physical + UInt64(k))) }
      blocks[slot(k)] = VerifiedBlock(block: physical + UInt64(k), checksum: sum, bytes: block)
    }
    return bytes
  }
}

extension FileSystem where Device: ConcurrentReadable {
  /// A lock-free reader for another thread (S1f), caching up to
  /// `cacheNodes` nodes and `cacheBlocks` file blocks; nil if all
  /// `EpochManager.readers` slots are taken. The first starts the writer
  /// publishing snapshots.
  public mutating func reader(cacheNodes: Int = 256, cacheBlocks: Int = 1024) -> FileReader<Device>? {
    let epochs = engine.enableReaders()
    return FileReader(epochs: epochs, device: engine.store.volume.device, cacheNodes: cacheNodes,
                      cacheBlocks: cacheBlocks)
  }
}
