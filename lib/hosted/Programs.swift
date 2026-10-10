// SPDX-License-Identifier: BSD-3-Clause

// The programs a hosted boot can start, by the name manifests give in
// `program`. Natively, these are images in bootfs (M3).

import IPC
import Launch
import Node

/// Every hosted program, by name.
public let hostedPrograms: [String: ProgramEntry] = [
  "hello": hello,
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
