// SPDX-License-Identifier: BSD-3-Clause

// The launcher (N0e): manifests and their errors, processes with only what
// their manifests grant, restarts and reconnecting, sealing, /srv.

import Glibc
import IDL
import IPC
import Launch
import Node
import Testing

/// A program that serves a tree about itself:
/// - `status`: its name and arguments;
/// - `ns`: its namespace's mount points, and whether it is sealed;
/// - `svc`: what its /svc lists;
/// - `peer`: the text at the path its first argument names, read through
///   its namespace each time;
/// - `ctl`: `exit CODE` ends it; `post NAME` posts its tree to /srv.
let treeProgram = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let name = start.name, args = start.args, ns = start.namespace
    final class Board: @unchecked Sendable { var client: SrvIPC.BoardClient? }
    let board = Board()
    if args.contains("--post") { board.client = try start.board() }
    tree.text("status", read: { "\(name) \(args.joined(separator: " "))\n" })
    tree.text("ns", read: { "\(ns.mountPoints.joined(separator: " ")) sealed \(ns.sealed)\n" })
    tree.text("svc", read: { ((try? ns.list("/svc").map(\.name)) ?? []).joined(separator: " ") + "\n" })
    tree.text("peer", read: {
      guard let path = args.first else { return "" }
      do {
        var c = try ns.open(path)
        return try c.readText()
      } catch {
        return "error \(error)\n"
      }
    })
    tree.text("ctl", read: { "" }, write: { command throws(NodeError) in
      let words = command.split(separator: " ").map(String.init)
      if words.count == 2, words[0] == "exit", let code = Int64(words[1]) { Process.exit(code: code) }
      guard words.count == 2, words[0] == "post", board.client != nil else { throw .invalid }
      do {
        let ends = try Channel.create()
        try tree.serve(ends.b)
        try board.client!.post(words[1], ends.a)
      } catch {
        throw .io
      }
    })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 99)
  }
}

/// A program that exits at once with the code its first argument gives.
let exiter = ProgramEntry { handle in
  let args = (try? Startup(handle))?.args ?? []
  Process.exit(code: Int64(args.first ?? "") ?? 0)
}

let programs = [("tree", treeProgram), ("exiter", exiter)]

func launcher() throws -> Launcher { try Launcher(programs: programs, rootJob: try Job.root()) }

func read(_ l: Launcher, _ service: String, _ leaf: String) throws -> String {
  var root = try l.open(service)
  var c = try root.open(leaf)
  return try c.readText()
}

/// Waits until the launcher's status has `line`.
func waitFor(_ l: Launcher, _ line: String, ms: Int = 3000) -> Bool {
  for _ in 0..<(ms / 5) {
    if l.status.contains(line + "\n") { return true }
    sleep(until: Clock.monotonic() + 5_000_000)
  }
  return false
}

func launchError(_ files: [(String, String)]) -> String {
  do {
    let l = try launcher()
    defer { l.stop() }
    try l.start(files.map { (path: $0.0, text: $0.1) })
    return "started"
  } catch {
    return "\(error)"
  }
}

@Test func manifestsFailLoudlyWithTheirLine() {
  let ok = "service a\nprogram tree\nexport\n"
  #expect(launchError([("a.m", "service a\nprogram tree\nbogus 1\n")]) == "a.m:3: unknown directive 'bogus'")
  #expect(launchError([("a.m", "# comment\nprogram tree\n")]) == "a.m:2: 'service' must come first")
  #expect(launchError([("a.m", "service a\n")]) == "a.m: no 'program'")
  #expect(launchError([("a.m", "service a\nprogram tree\nrestart sometimes\n")])
    == "a.m:3: 'restart' takes never, on-failure or always")
  #expect(launchError([("a.m", "service a\nprogram tree\nexport now\n")]) == "a.m:3: 'export' takes 0 arguments")
  #expect(launchError([("a.m", "service a\nprogram tree\nmount data a\n")]) == "a.m:3: bad path 'data'")
  #expect(launchError([("a.m", "service a\nprogram tree\nmount /data a sideways\n")])
    == "a.m:3: unknown mount option 'sideways'")
  #expect(launchError([("a.m", "service a\nprogram nothing\n")]) == "a.m:2: no program 'nothing'")
  #expect(launchError([("a.m", ok), ("b.m", "service b\nprogram tree\n\nuse block\n")]) == "b.m:4: no service 'block'")
  #expect(launchError([("a.m", "service a\nprogram tree\n"), ("b.m", "service b\nprogram tree\nuse a\n")])
    == "b.m:3: service 'a' exports nothing")
  #expect(launchError([("a.m", ok), ("a2.m", "# again\nservice a\nprogram tree\n")])
    == "a2.m:2: service 'a' is also defined at a.m:1")
  #expect(launchError([("a.m", ok + "use b\n"), ("b.m", "service b\nprogram tree\nexport\nuse a\n")])
    == "a.m:1: services depend on each other: a → b → a")
}

@Test func processesGetWhatTheirManifestsGrantAndNothingElse() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\narg hello there\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse a\narg /svc/a/status\n"),
    ("c.m", "service c\nprogram tree\nexport\n"),
    ("d.m", "service d  # mounts a's tree directly, after nothing\nprogram tree\nexport\nmount /data a\narg /data/status\n"),
  ])
  #expect(try read(l, "a", "status") == "a hello there\n")
  #expect(try read(l, "b", "peer") == "a hello there\n")
  #expect(try read(l, "b", "ns") == "/svc sealed false\n")
  #expect(try read(l, "b", "svc") == "a\n")  // only what it uses
  #expect(try read(l, "c", "ns") == " sealed false\n")
  #expect(try read(l, "d", "peer") == "a hello there\n")
  #expect(l.status == "a running restarts 0\nb running restarts 0\nc running restarts 0\nd running restarts 0\n")
}

@Test func aRestartedServiceIsReachedAgainThroughSvc() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\nrestart always\narg first\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse a\narg /svc/a/status\n"),
  ])
  #expect(try read(l, "b", "peer") == "a first\n")
  var held = try l.open("a")
  var ctl = try held.open("ctl")
  _ = try? ctl.writeText("exit 3")  // the reply never comes: it has ended
  #expect(waitFor(l, "a running restarts 1"))
  // A channel to the old instance is closed; b's next open reaches the new one.
  var closed = false
  do throws(NodeIPC.NodeClient.Failure) { _ = try held.stat(0) } catch {
    if case .transport(.peerClosed) = error { closed = true }
  }
  #expect(closed)
  #expect(try read(l, "b", "peer") == "a first\n")
}

@Test func restartPoliciesAreFollowed() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("n.m", "service n\nprogram exiter\nrestart never\narg 3\n"),
    ("z.m", "service z\nprogram exiter\nrestart on-failure\narg 0\n"),
    ("f.m", "service f\nprogram exiter\nrestart on-failure\narg 4\n"),
  ])
  #expect(waitFor(l, "n exited 3 restarts 0"))
  #expect(waitFor(l, "z exited 0 restarts 0"))
  // A service that fails at once, again and again, is given up on.
  #expect(waitFor(l, "f failed (restarted 5 times in 30 s) restarts \(Launcher.maxRestarts)"))
}

@Test func sealedManifestsSealTheNamespace() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\n"),
    ("s.m", "service s\nprogram tree\nexport\nuse a\nseal\n"),
  ])
  #expect(try read(l, "s", "ns") == "/svc sealed true\n")
}

@Test func programsFindEachOtherOnSrv() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("p.m", "service p\nprogram tree\nexport\nsrv\narg --post\n"),
    ("q.m", "service q\nprogram tree\nexport\nsrv\narg /srv/editor/status\n"),
  ])
  var p = try l.open("p")
  var ctl = try p.open("ctl")
  try ctl.writeText("post editor")
  #expect(try read(l, "q", "peer") == "p --post\n")
  #expect(try read(l, "q", "ns") == "/srv sealed false\n")
}

@Test func checkedInOutputsMatchIdlc() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/launch/LaunchTests.swift
  let root = parts.joined(separator: "/")
  func read(_ path: String) -> String? {
    guard let f = fopen("\(root)/\(path)", "r") else { return nil }
    defer { fclose(f) }
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = fread(&buffer, 1, buffer.count, f)
      if n == 0 { break }
      out += buffer[..<n]
    }
    return String(decoding: out, as: UTF8.self)
  }
  let source = "lib/launch/Startup.swift"
  let text = try #require(read(source))
  let (library, p) = try #require(try scan([(source, text)]).protocols.first)
  let regenerate = "regenerate: .build/debug/idlc --c-out lib/launch/idl --doc-out lib/launch/idl \(source)"
  #expect(cHeader(library, source: source) == read("lib/launch/idl/launch_ipc.h"), "\(regenerate)")
  #expect(markdown(p, library, source: source) == read("lib/launch/idl/Startup.md"), "\(regenerate)")
  #expect(Baseline(p, library).text == read("lib/launch/idl/\(p.id).api"))
}

/// `resource` and `programs` (M3g) grant only what the launcher was
/// allowed: hosted it has neither unless a test gives it a stand-in.
@Test func hardwareGrantsNeedTheLaunchersOwn() throws {
  #expect(launchError([("d.m", "service d\nprogram tree\nresource mmio\nexport\n")])
    == "d.m:3: no 'mmio' resource to grant")
  #expect(launchError([("d.m", "service d\nprogram tree\nexport\nprograms\n")]) == "d.m:4: no bootfs to grant")
  #expect(launchError([("d.m", "service d\nprogram tree\nbootdata\n")]) == "d.m:3: no boot data to grant")
  let l = try launcher()
  defer { l.stop() }
  l.allow(resource: .mmio, try Event.create())
  l.allow(bootfs: try VMO.create(size: 4096))
  l.allow(bootData: try VMO.create(size: 4096))
  try l.start([(path: "d.m", text: "service d\nprogram tree\nresource mmio\nprograms\nbootdata\nexport\n")])
  #expect(waitFor(l, "d running restarts 0"))
}
