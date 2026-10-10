// SPDX-License-Identifier: BSD-3-Clause

// The programs a hosted boot can start, by the name manifests give in
// `program`, over the bodies both boots share (lib/services). Natively,
// they are programs in bootfs (boot/programs).

import Block
import Glibc
import Launch
import Services
import Sys

/// Every hosted program, by name.
public let hostedPrograms: [(name: String, entry: ProgramEntry)] = [
  ("hello", hello),
  ("block", block),
  ("fs", fsProgram),
  ("catalog", catalog),
]

/// A small service: `status` says who it is and what its namespace holds.
let hello = ProgramEntry { handle in
  do { try Services.hello(try Startup(handle)) } catch { Process.exit(code: 1) }
}

/// The block service over an image file:
///
///     block [--create SIZE] [--read-only] IMAGE
///
/// --create makes the image (and its directory) if need be, and sizes it:
/// SIZE in bytes, or with K, M or G (binary).
let block = ProgramEntry { handle in
  do {
    let start = try Startup(handle)
    var path: String?, size: UInt64?, readOnly = false
    var args = start.args[...]
    while let arg = args.popFirst() {
      switch arg {
      case "--create":
        guard let s = args.popFirst().flatMap(Services.parseSize) else { Process.exit(code: 2) }
        size = s
      case "--read-only": readOnly = true
      default: path = arg
      }
    }
    guard let path else { Process.exit(code: 2) }
    if size != nil { makeDirectories(containing: path) }
    let backend = try FileBackend(path: path, blocks: size.map { $0 / 4096 }, readOnly: readOnly)
    try Services.block(start, backend: backend, name: path)
  } catch {
    Process.exit(code: 1)
  }
}

/// mkdir -p for a file's directory.
func makeDirectories(containing path: String) {
  var at = path.startIndex
  while let slash = path[at...].dropFirst().firstIndex(of: "/") {
    mkdir(String(path[..<slash]), 0o755)
    at = slash
  }
}

/// The fs service (Services.fs), with random volume UUIDs.
let fsProgram = ProgramEntry { handle in
  do {
    try Services.fs(try Startup(handle)) {
      var random = SystemRandomNumberGenerator()
      return (0..<16).map { _ in random.next() }
    }
  } catch {
    Process.exit(code: 1)
  }
}

/// N0's exit, as a client (Services.catalog).
let catalog = ProgramEntry { handle in
  do { try Services.catalog(try Startup(handle)) } catch { Process.exit(code: 1) }
}
