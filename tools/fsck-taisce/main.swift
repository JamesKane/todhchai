// SPDX-License-Identifier: BSD-3-Clause

// fsck.taisce IMAGE
// Mounts IMAGE (its newest valid superblock; freeing orphans, as any mount
// does) and scrubs it: every node is read from the image and checked
// against the BLAKE3-128 its parent records, and every invariant holds (the
// trees, free space, link counts, names, extents, indices). Exits 0 if
// clean.

import Glibc
import Taisce
import TaisceHost

guard CommandLine.arguments.count == 2 else { ToolSupport.fail("usage: fsck.taisce IMAGE") }
let image = CommandLine.arguments[1]
do {
  var fs = try FileSystem.mount(FileDevice(path: image))
  let nodes = try fs.check()
  let metadata = try fs.engine.nodeBlocks().count / Layout.nodeBlocks
  let copies = try fs.engine.store.volume.intactCopies()
  let a = fs.engine.store.volume.allocator
  let indices = fs.indices.map { String(decoding: $0.name, as: UTF8.self) }.joined(separator: ", ")
  let txg = fs.engine.store.volume.superblock.txg
  print("fsck.taisce: \(image): clean at txg \(txg) (\(copies) of 2 superblock copies intact). \(metadata) tree nodes read and verified; \(nodes) files and directories; \(a.blockCount - a.freeCount) of \(a.blockCount) blocks in use; indices: \(indices); journal at \(fs.nextSeq - 1)")
} catch {
  ToolSupport.fail("fsck.taisce: \(image): \(error)")
}
