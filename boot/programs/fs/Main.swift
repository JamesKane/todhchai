// SPDX-License-Identifier: BSD-3-Clause

// bin/fs, natively (M3e): the fs service (Services.fs). croi has no random
// source yet (croi-requirements), so a new volume's UUID comes from the
// clock and this process's koid, mixed: unique enough for one machine's
// ramdisk, and to be replaced by the kernel's entropy.

import Launch
import LibSys
import Services
import Sys

@main struct FsProgram {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    do {
      try Services.fs(try Startup(Handle(raw: raw))) {
        var state = UInt64(bitPattern: Clock.monotonic()) ^ ((try? Process.current().info().koid) ?? 0) << 32
        var uuid: [UInt8] = []
        for _ in 0..<2 {
          // splitmix64
          state &+= 0x9E37_79B9_7F4A_7C15
          var z = state
          z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
          z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
          z ^= z >> 31
          for i in 0..<8 { uuid.append(UInt8(truncatingIfNeeded: z >> (8 * UInt64(i)))) }
        }
        return uuid
      }
    } catch {
      exit(1)
    }
  }
}
