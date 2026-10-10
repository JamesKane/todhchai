// SPDX-License-Identifier: BSD-3-Clause

// bin/tree-service: a service the native launcher starts from bootfs (M3d).
// It reads its Startup (the PA_USER0 handle), serves a Node tree on its
// export channel and says it is ready:
//
// - `status`: its name, arguments and instance (the koid of its process,
//   which changes when the launcher restarts it);
// - `ctl`: `exit CODE` ends it, as a crash would.

import IPC
import LibSys
import Launch
import Node
import Sys

@main struct TreeService {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else {
      print("tree-service: started without a Startup handle")
      exit(2)
    }
    do {
      var start = try Startup(Handle(raw: raw))
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let name = start.name, args = start.args
      let instance = (try? Process.current().info().koid) ?? 0
      tree.text("status", read: { "\(name) \(args.joined(separator: " ")) instance \(instance)\n" })
      tree.text("ctl", read: { "" }, write: { command throws(NodeError) in
        let words = command.split(separator: " ")
        guard words.count == 2, words[0] == "exit", let code = Int64(String(words[1])) else { throw .invalid }
        exit(code)
      })
      try tree.serve(try start.export())
      try start.ready()
      try dispatcher.run()
    } catch {
      print("tree-service: failed")
      exit(99)
    }
  }
}
