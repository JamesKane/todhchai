// SPDX-License-Identifier: BSD-3-Clause

// The programs a hosted boot can start, by the name manifests give in
// `program`. Natively, these are images in bootfs (M3).

import Block
import Glibc
import IPC
import Launch
import Node

/// Every hosted program, by name.
public let hostedPrograms: [String: ProgramEntry] = [
  "hello": hello,
  "block": block,
]

/// A small service: `status` says who it is and what its namespace holds.
let hello = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let name = start.name, ns = start.namespace
    tree.text("status", read: { "hello from \(name); namespace: \(ns.mountPoints.joined(separator: " "))\n" })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

/// The block service over an image file:
///
///     block [--create SIZE] [--read-only] IMAGE
///
/// --create makes the image (and its directory) if need be, and sizes it:
/// SIZE in bytes, or with K, M or G (binary).
let block = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    var path: String?, size: UInt64?, readOnly = false
    var args = start.args[...]
    while let arg = args.popFirst() {
      switch arg {
      case "--create":
        guard let s = args.popFirst().flatMap(parseSize) else { Process.exit(code: 2) }
        size = s
      case "--read-only": readOnly = true
      default: path = arg
      }
    }
    guard let path else { Process.exit(code: 2) }
    if size != nil { makeDirectories(containing: path) }
    let backend = try FileBackend(path: path, blocks: size.map { $0 / 4096 }, readOnly: readOnly)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    BlockService(backend: backend, name: path, dispatcher: dispatcher).publish(in: tree)
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

/// "64M": 64 MiB.
func parseSize(_ text: String) -> UInt64? {
  let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
  guard let last = text.last else { return nil }
  if let unit = units[last] { return UInt64(text.dropLast()).map { $0 * unit } }
  return UInt64(text)
}

/// mkdir -p for a file's directory.
func makeDirectories(containing path: String) {
  var at = path.startIndex
  while let slash = path[at...].dropFirst().firstIndex(of: "/") {
    mkdir(String(path[..<slash]), 0o755)
    at = slash
  }
}
