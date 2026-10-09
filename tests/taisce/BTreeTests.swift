// SPDX-License-Identifier: BSD-3-Clause

// S0b: the B+tree against an in-memory model: random inserts, replaces
// and deletes, then every invariant, every lookup, range scans, and the
// same after the nodes are written and the volume reopened.

import Taisce
import Testing

/// A deterministic generator, so a failure replays.
struct SplitMix {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

func bigEndian(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }

func newStore(blocks: UInt64 = 65_536, cacheNodes: Int = 512) throws -> Store<MemoryDevice> {
  Store(try Volume.format(MemoryDevice(blocks: blocks), label: [], uuid: Array(1...16), now: 0), cacheNodes: cacheNodes)
}

@Test func anEmptyTreeHasNothing() throws {
  var store = try newStore()
  var tree = BTree()
  #expect(try tree.get([1], &store) == nil)
  #expect(try tree.scan(from: [], &store).isEmpty)
  #expect(try tree.delete([1], &store) == false)
  #expect(try tree.check(&store).entries == 0)
}

@Test func oversizedEntriesAreRefused() throws {
  var store = try newStore()
  var tree = BTree()
  #expect(throws: TaisceError.tooLarge) { try tree.insert([UInt8](repeating: 1, count: 1025), [], &store) }
  #expect(throws: TaisceError.tooLarge) { try tree.insert([1], [UInt8](repeating: 1, count: 3073), &store) }
}

@Test(arguments: [(seed: UInt64(1), valueBytes: 8), (seed: 2, valueBytes: 300), (seed: 3, valueBytes: 3000)])
func randomOperationsMatchAModel(seed: UInt64, valueBytes: Int) throws {
  var rng = SplitMix(state: seed)
  var store = try newStore(cacheNodes: 8)  // a small cache, so nodes are evicted and reread
  var tree = BTree()
  var model: [[UInt8]: [UInt8]] = [:]
  let keySpace = 4000
  let freeAtStart = store.volume.allocator.freeCount

  func value(_ k: Int, _ version: UInt64) -> [UInt8] {
    var v = bigEndian(UInt64(k)) + bigEndian(version)
    while v.count < valueBytes { v.append(UInt8(truncatingIfNeeded: v.count &* 31 &+ k)) }
    return Array(v.prefix(max(valueBytes, 1)))
  }

  for round in 0..<6 {
    for _ in 0..<1500 {
      let k = rng.below(keySpace)
      let key = bigEndian(UInt64(k))
      if rng.below(10) < (round < 3 ? 7 : 3) {  // grow, then shrink
        let v = value(k, rng.next())
        try tree.insert(key, v, &store)
        model[key] = v
      } else {
        #expect(try tree.delete(key, &store) == (model.removeValue(forKey: key) != nil))
      }
    }
    let stats = try tree.check(&store)
    #expect(stats.entries == model.count)
    for k in stride(from: 0, to: keySpace, by: 7) {
      let key = bigEndian(UInt64(k))
      #expect(try tree.get(key, &store) == model[key])
    }
    // A range scan returns exactly the model's keys in that range, in order.
    let lo = rng.below(keySpace), hi = lo + rng.below(500)
    let scanned = try tree.scan(from: bigEndian(UInt64(lo)), to: bigEndian(UInt64(hi)), &store)
    let expected = model.keys.filter { !$0.lexicographicallyPrecedes(bigEndian(UInt64(lo))) && $0.lexicographicallyPrecedes(bigEndian(UInt64(hi))) }
      .sorted { $0.lexicographicallyPrecedes($1) }
    #expect(scanned.map(\.key) == expected)
    #expect(scanned.allSatisfy { model[$0.key] == $0.value })
  }

  // Written and reopened, the tree is the same.
  try store.writeDirty()
  try store.volume.commit { $0.treeRoot = tree.root }
  var reopened = Store(try Volume.open(store.volume.device))
  let again = BTree(root: reopened.volume.superblock.treeRoot)
  #expect(try again.check(&reopened).entries == model.count)
  #expect(try again.scan(from: [], &reopened).map(\.key) == model.keys.sorted { $0.lexicographicallyPrecedes($1) })

  // Emptied, every node's blocks come back.
  for key in model.keys { try tree.delete(key, &store) }
  #expect(tree.root == 0)
  #expect(store.volume.allocator.freeCount == freeAtStart)
}

@Test func scansStopAtTheLimitAndTheEnd() throws {
  var store = try newStore()
  var tree = BTree()
  for k in 0..<2000 { try tree.insert(bigEndian(UInt64(k)), [UInt8(k & 0xff)], &store) }
  #expect(try tree.check(&store).depth >= 2)
  let some = try tree.scan(from: bigEndian(100), limit: 5, &store)
  #expect(some.map(\.key) == (100..<105).map { bigEndian(UInt64($0)) })
  let tail = try tree.scan(from: bigEndian(1995), &store)
  #expect(tail.count == 5)
  #expect(try tree.scan(from: bigEndian(5000), &store).isEmpty)
  // Keys between existing ones start at the next.
  #expect(try tree.scan(from: bigEndian(10) + [0], limit: 1, &store).first?.key == bigEndian(11))
}

@Test func theCheckerCatchesBrokenTrees() throws {
  var store = try newStore()
  var tree = BTree()
  for k in 0..<3000 { try tree.insert(bigEndian(UInt64(k)), [UInt8](repeating: 7, count: 40), &store) }
  #expect(try tree.check(&store).depth >= 2)
  let root = try store.node(tree.root)

  // Keys out of order in a leaf.
  let leafBlock = root.children[0]
  let leaf = try store.node(leafBlock)
  var swapped = leaf
  swapped.keys.swapAt(0, 1)
  store.put(leafBlock, swapped)
  #expect(throws: TaisceError.corrupt(.tree(.keysOutOfOrder))) { try tree.check(&store) }
  store.put(leafBlock, leaf)

  // A key that belongs in the next leaf.
  var stray = leaf
  stray.keys[stray.keys.count - 1] = bigEndian(999_999)
  store.put(leafBlock, stray)
  #expect(throws: TaisceError.corrupt(.tree(.keyOutsideItsBounds))) { try tree.check(&store) }
  store.put(leafBlock, leaf)

  // A node whose blocks the allocator thinks are free.
  store.volume.allocator.free(Extent(start: leafBlock, count: 1))
  #expect(throws: TaisceError.corrupt(.tree(.blockNotAllocated))) { try tree.check(&store) }
  _ = try store.volume.allocator.allocateContiguous(1, near: leafBlock)
  #expect(try tree.check(&store).entries == 3000)
}
