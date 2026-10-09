// SPDX-License-Identifier: BSD-3-Clause

// S0a: checksums, the superblock, free space, and format/open.

import Glibc
import Taisce
import TaisceHost
import Testing

@Test func crc32cMatchesRFC3720() {
  // RFC 3720 §B.4's test vectors, and the common check value.
  #expect(CRC32C.checksum([UInt8](repeating: 0, count: 32)) == 0x8A91_36AA)
  #expect(CRC32C.checksum([UInt8](repeating: 0xFF, count: 32)) == 0x62A8_AB43)
  #expect(CRC32C.checksum(Array(0...31)) == 0x46DD_794E)
  #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
}

@Test func theLayoutPacksRegionsInOrder() throws {
  let l = try Layout(blockCount: 262_144)  // 1 GiB
  #expect(l.logStart == 2)
  #expect(l.logBlocks == 2621)  // 1%
  #expect(l.bitmapStart == 2 + 2621)
  #expect(l.bitmapBlocks == 8)  // 262,144 bits
  #expect(l.dataStart == 2 + 2621 + 8)
  #expect(throws: TaisceError.tooSmall) { try Layout(blockCount: 100) }
}

@Test func aSuperblockRoundTripsAndRejectsDamage() throws {
  var s = Superblock(layout: try Layout(blockCount: 10_000), uuid: Array(1...16), label: Array("home".utf8),
                     createdNs: 42)
  s.catalogRoot = 777
  s.generation = 9
  var block = s.encode()
  #expect(try Superblock.decode(block) == s)
  block[200] ^= 1  // a flipped bit anywhere fails the checksum
  #expect(try Superblock.decode(block) == nil)
  #expect(try Superblock.decode([UInt8](repeating: 0, count: 4096)) == nil)
}

@Test func theAllocatorHandsOutExtentsAndPersists() throws {
  var a = Allocator(blockCount: 1000, reserved: 10)
  #expect(a.freeCount == 990)
  let first = try a.allocate(100)
  #expect(first == [Extent(start: 10, count: 100)])
  let node = try a.allocateContiguous(4, near: 500)
  #expect(node == Extent(start: 500, count: 4))
  a.free(Extent(start: 20, count: 10))
  // A request bigger than the hole spans extents, first fit from the hint.
  let spread = try a.allocate(15, near: 15)
  #expect(spread == [Extent(start: 20, count: 10), Extent(start: 110, count: 5)])
  #expect(a.freeCount == 990 - 100 - 4 + 10 - 15)
  #expect(throws: TaisceError.noSpace) { try a.allocate(10_000) }

  // Stored and loaded, it's the same.
  var bitmap: [UInt8] = []
  for (_, bytes) in a.dirtyBlocks() { bitmap += bytes }
  var b = try Allocator(blockCount: 1000, bitmap: bitmap)
  #expect(b.freeCount == a.freeCount)
  for block in UInt64(0)..<1000 { #expect(b.isUsed(block) == a.isUsed(block)) }
  #expect(throws: TaisceError.noSpace) { try b.allocateContiguous(1000) }
}

@Test func aFormattedVolumeOpens() throws {
  let v = try Volume.format(MemoryDevice(blocks: 4096), label: Array("test".utf8), uuid: Array(1...16), now: 7)
  let device = v.device
  let opened = try Volume.open(device)
  #expect(opened.superblock == v.superblock)
  #expect(opened.allocator.freeCount == v.allocator.freeCount)
  #expect(throws: TaisceError.notAVolume) { try Volume.open(MemoryDevice(blocks: 64)) }
}

@Test func aTornSuperblockWriteFallsBackToTheOtherCopy() throws {
  var v = try Volume.format(MemoryDevice(blocks: 4096), label: [], uuid: Array(1...16), now: 0)
  let before = v.superblock
  try v.commit { $0.catalogRoot = 1234 }
  #expect(try Volume.open(v.device).superblock.catalogRoot == 1234)
  // Tear the newest copy: the previous generation is what mounts.
  var damaged = v.device
  try damaged.write(v.superblock.slot, [UInt8](repeating: 0xAB, count: 4096))
  let opened = try Volume.open(damaged)
  #expect(opened.superblock.generation == before.generation)
  #expect(opened.superblock.catalogRoot == 0)
}

@Test func aCommitIsOrderedByBarriers() throws {
  let v = try Volume.format(MemoryDevice(blocks: 4096), label: [], uuid: Array(1...16), now: 0)
  var r = try Volume.open(RecordingDevice(v.device))
  _ = try r.allocator.allocate(50)
  try r.commit()
  let log = r.device.log
  // Bitmap, a barrier, the superblock, a barrier.
  #expect(log.count == 4)
  guard case .write(let bitmapBlock, _) = log[0], case .write(let superBlock, _) = log[2] else {
    Issue.record("unexpected log \(log)")
    return
  }
  #expect(bitmapBlock == r.superblock.layout.bitmapStart)
  #expect(log[1] == .flush && log[3] == .flush)
  #expect(superBlock == r.superblock.slot)
  // Any prefix of the log mounts, before or after the commit.
  for k in 0...log.count {
    let crashed = v.device.applying(log.prefix(k))
    let opened = try Volume.open(crashed)
    #expect(opened.superblock.generation == (k >= 3 ? r.superblock.generation : v.superblock.generation))
  }
}

@Test func aFileDeviceHoldsAVolume() throws {
  let path = "/tmp/taisce-test-\(getpid()).img"
  defer { unlink(path) }
  let v = try Volume.format(FileDevice(path: path, blocks: 2048), label: Array("img".utf8), uuid: Array(1...16), now: 1)
  let sb = v.superblock
  _ = consume v
  let opened = try Volume.open(FileDevice(path: path))
  #expect(opened.superblock == sb)
}
