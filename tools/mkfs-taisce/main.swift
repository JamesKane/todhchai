// SPDX-License-Identifier: BSD-3-Clause

// mkfs.taisce [-L LABEL] [-s SIZE] IMAGE
// Makes a Taisce volume in IMAGE (a file, made or resized to SIZE; default
// 1G, sparse).

import Glibc
import Taisce
import TaisceHost

var label = "taisce", size: UInt64 = 1 << 30, image: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
  switch a {
  case "-L":
    guard let l = args.popFirst() else { ToolSupport.fail("mkfs.taisce: -L needs a label") }
    label = l
  case "-s":
    guard let s = args.popFirst().flatMap(ToolSupport.size) else { ToolSupport.fail("mkfs.taisce: -s needs a size such as 512M") }
    size = s
  default: image = a
  }
}
guard let image else { ToolSupport.fail("usage: mkfs.taisce [-L LABEL] [-s SIZE] IMAGE") }
do {
  let device = try FileDevice(path: image, blocks: size / UInt64(Layout.blockSize))
  var fs = try FileSystem.format(device, label: Array(label.utf8), uuid: ToolSupport.uuid(),
                                 now: ToolSupport.now)
  // The root belongs to whoever made the volume (as mkfs.ext4's root_owner).
  try fs.setAttributes(FileSystem<FileDevice>.root, uid: getuid(), gid: getgid(), now: ToolSupport.now)
  try fs.sync()
  let layout = fs.engine.store.volume.superblock.layout
  print("mkfs.taisce: \(image): \(layout.blockCount) blocks of 4 KiB, label \"\(label)\"")
} catch {
  ToolSupport.fail("mkfs.taisce: \(image): \(error)")
}
