// SPDX-License-Identifier: BSD-3-Clause

// S1e: fsync through the intent log.

import Taisce
import Testing

@Test func anFsyncSurvivesACrashAndWhatFollowsDoesNot() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, n("committed"), now: 3)
  try fs.sync()
  let txg = fs.engine.store.volume.superblock.txg
  try fs.write(f, offset: 0, n("fsynced!!"), now: 4)
  try fs.setAttribute(f, n("user:x"), .int64(7), now: 4)
  let g = try fs.create(root, n("g"), .file, mode: 0o644, now: 4)
  try fs.fsync()
  #expect(fs.engine.store.volume.superblock.txg == txg)  // no group commit
  try fs.write(f, offset: 0, n("lost....."), now: 5)
  _ = try fs.create(root, n("h"), .file, mode: 0o644, now: 5)
  // A crash: the device as it is.
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.read(f, offset: 0, count: 9) == n("fsynced!!"))
  #expect(try after.attribute(f, n("user:x")) == .int64(7))
  #expect(try after.lookup(root, n("g")) == g)
  #expect(throws: TaisceError.notFound) { try after.lookup(root, n("h")) }
  try after.check()
  // Mounting replayed and committed it; again, it's all still there.
  var again = try FileSystem.mount(after.engine.store.volume.device)
  #expect(try again.read(f, offset: 0, count: 9) == n("fsynced!!"))
}

@Test func writesAfterAnFsyncDontOverwriteWhatItPromised() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  let first = [UInt8](repeating: 1, count: 20_000)
  try fs.write(f, offset: 0, first, now: 3)  // fresh blocks, written in place until...
  try fs.fsync()  // ...the log names them: from now on, new writes go elsewhere
  try fs.write(f, offset: 0, [UInt8](repeating: 2, count: 20_000), now: 4)
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.read(f, offset: 0, count: 20_000) == first)
  try after.check()
}

@Test func aFullIntentLogCommitsInstead() throws {
  var fs = try newFS(blocks: 4096)  // a 256-block intent log
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  let txg = fs.engine.store.volume.superblock.txg
  for i in 0..<400 {
    try fs.setAttribute(f, n("user:big"), .bytes([UInt8](repeating: UInt8(i & 0xff), count: 3000)), now: 3)
    try fs.fsync()
  }
  #expect(fs.engine.store.volume.superblock.txg > txg)  // it filled, and committed
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.attribute(f, n("user:big")) == .bytes([UInt8](repeating: UInt8(399 & 0xff), count: 3000)))
  try after.check()
}

@Test func aDamagedRecordEndsReplay() throws {
  var fs = try newFS(blocks: 4096)
  let layout = fs.engine.store.volume.superblock.layout
  _ = try fs.create(root, n("one"), .file, mode: 0o644, now: 2)
  try fs.fsync()  // record 0, at the start of the log
  _ = try fs.create(root, n("two"), .file, mode: 0o644, now: 3)
  try fs.fsync()  // record 1, after it
  var image = fs.engine.store.volume.device
  // Find record 1's header (the second "TInt" block) and damage it.
  var headers: [UInt64] = []
  for b in layout.intentStart..<(layout.intentStart + layout.intentBlocks) {
    let block = try image.read(b, count: 1)
    if block[0] == 0x54, block[1] == 0x49, block[2] == 0x6E, block[3] == 0x74 { headers.append(b) }
  }
  #expect(headers.count == 2)
  var block = try image.read(headers[1], count: 1)
  block[60] ^= 1
  try image.write(headers[1], block)
  var after = try FileSystem.mount(image)
  #expect(try after.lookup(root, n("one")) > 0)
  #expect(throws: TaisceError.notFound) { try after.lookup(root, n("two")) }
  try after.check()
}
