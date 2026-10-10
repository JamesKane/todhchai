// SPDX-License-Identifier: BSD-3-Clause

// bin/block, natively (M3e): the block service (Services.block) over a
// ramdisk (VMOBackend) until M3h's virtio-blk:
//
//     block --memory SIZE      # SIZE in bytes, or with K, M or G (binary)
//
// The disk lives as long as the service: the fs service's restarts find
// their volume, a reboot doesn't.

import Block
import Launch
import LibSys
import Services
import Sys

@main struct BlockProgram {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    do {
      let start = try Startup(Handle(raw: raw))
      guard start.args.count == 2, start.args[0] == "--memory", let size = Services.parseSize(start.args[1]),
        size >= 4096
      else { exit(2) }
      try Services.block(start, backend: try VMOBackend(blocks: size / 4096), name: "memory")
    } catch {
      exit(1)
    }
  }
}
