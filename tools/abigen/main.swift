// SPDX-License-Identifier: BSD-3-Clause

// abigen KEYUSAGE.swift C_HEADER ZIG ODIN
// Writes libtodhchai's C header and Zig and Odin bindings from the ABI
// description (lib/capi/gen/Todhchai.swift).

import ABIGen
import FoundationEssentials
import Glibc

let args = CommandLine.arguments
guard args.count == 5, let keys = try? String(contentsOfFile: args[1], encoding: .utf8) else {
  print("usage: abigen KeyUsage.swift todhchai.h todhchai.zig todhchai.odin")
  exit(2)
}
let abi = todhchaiABI(keys: keyUsages(in: keys))
for (path, text) in [(args[2], emitC(abi)), (args[3], emitZig(abi)), (args[4], emitOdin(abi))] {
  do {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
  } catch {
    print("abigen: can't write \(path): \(error)")
    exit(1)
  }
}
