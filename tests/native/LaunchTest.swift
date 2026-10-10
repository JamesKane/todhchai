// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-test: the native launcher's test (M3d), a client it starts
// from bootfs beside bin/tree-service (tests/native/manifests). Run by
//
//     td boot --test --manifests tests/native/manifests --cmdline launcher.until=launch-test
//
// It checks that its namespace holds what its manifest grants and nothing
// more, reads the tree service through /svc, crashes it through its `ctl`,
// and reads it again once the launcher has restarted it (on-failure): the
// same path reaches the new instance. The launcher exits with its code.

import IPC
import LibSys
import Launch
import Node
import Sys

@main struct LaunchTest {
  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok {
      print("launch-test: FAILED: \(what)")
      exit(1)
    }
  }

  static func status(_ ns: Namespace) -> String? {
    guard var c = try? ns.open("/svc/tree/status") else { return nil }
    return try? c.readText()
  }

  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else {
      print("launch-test: started without a Startup handle")
      exit(2)
    }
    let ns: Namespace
    do {
      let start = try Startup(Handle(raw: raw))
      check(start.args == ["--check", "1"], "the manifest's arguments")
      ns = start.namespace
    } catch {
      print("launch-test: FAILED: reading Startup")
      exit(1)
    }
    check(ns.sealed, "the namespace is sealed")
    check(ns.mountPoints == ["/svc"], "only /svc is mounted")
    let svc = (try? ns.list("/svc"))?.map { $0.name } ?? []
    check(svc == ["tree"], "/svc holds only the service it uses")

    // The tree service, through /svc.
    guard let first = status(ns) else {
      print("launch-test: FAILED: reading /svc/tree/status")
      exit(1)
    }
    check(first.utf8.starts(with: "tree --greeting dia-duit instance ".utf8), "the service's status")
    print("launch-test: \(first.split(separator: "\n").first.map(String.init) ?? "")")

    // A crash, and the launcher's restart: the same path, a new instance.
    if var ctl = try? ns.open("/svc/tree/ctl") { _ = try? ctl.writeText("exit 3") }
    let deadline = Clock.monotonic() + 5_000_000_000
    var second: String?
    while Clock.monotonic() < deadline {
      if let s = status(ns), s != first {
        second = s
        break
      }
      sleep(until: Clock.monotonic() + 20_000_000)
    }
    guard let second else {
      print("launch-test: FAILED: the service didn't come back")
      exit(1)
    }
    print("launch-test: restarted: \(second.split(separator: "\n").first.map(String.init) ?? "")")
    print("launch-test: ok")
  }
}
