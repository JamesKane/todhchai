// SPDX-License-Identifier: BSD-3-Clause

// taisce-fuse IMAGE MOUNTPOINT
// Serves a Taisce volume through FUSE until unmounted (fusermount3 -u
// MOUNTPOINT) or interrupted. /.taisce/{query,live,index} hold queries,
// live queries and index declarations (lib/taisce-host/FuseServer.swift).

import Glibc
import Taisce
import TaisceHost

guard CommandLine.arguments.count == 3 else { ToolSupport.fail("usage: taisce-fuse IMAGE MOUNTPOINT") }
let image = CommandLine.arguments[1], mountpoint = CommandLine.arguments[2]
do {
  let fs = try FileSystem.mount(FileDevice(path: image))
  let fd = try FuseMount.mount(mountpoint, name: image)
  ToolSupport.say("taisce-fuse: \(image) on \(mountpoint)")
  let server = FuseServer(fs, fd: fd)
  server.startReaders(4)  // lookups, attributes and reads, lock-free beside the writer (S1f)
  FuseMount.serve(server, at: mountpoint)
  ToolSupport.say("taisce-fuse: unmounted; synced")
} catch {
  ToolSupport.fail("taisce-fuse: \(error)")
}
