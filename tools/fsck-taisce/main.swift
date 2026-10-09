// SPDX-License-Identifier: BSD-3-Clause

// fsck.taisce IMAGE
// Mounts IMAGE (replaying its log and freeing orphans, as any mount does)
// and checks every invariant: the trees, free space, link counts, names,
// extents and indices (FileSystem.check). Exits 0 if clean.

import Glibc
import Taisce
import TaisceHost

guard CommandLine.arguments.count == 2 else { ToolSupport.fail("usage: fsck.taisce IMAGE") }
let image = CommandLine.arguments[1]
do {
  var fs = try FileSystem.mount(FileDevice(path: image))
  let nodes = try fs.check()
  let a = fs.engine.store.volume.allocator
  let indices = fs.indices.map { String(decoding: $0.name, as: UTF8.self) }.joined(separator: ", ")
  print("fsck.taisce: \(image): clean. \(nodes) nodes; \(a.blockCount - a.freeCount) of \(a.blockCount) blocks in use; indices: \(indices); journal at \(fs.nextSeq - 1)")
} catch {
  ToolSupport.fail("fsck.taisce: \(image): \(error)")
}
