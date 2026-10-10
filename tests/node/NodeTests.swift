// SPDX-License-Identifier: BSD-3-Clause

// Node over the tree helper (N0c): walks, stat, reads and writes, text
// leaves, paging, watches, create and remove.

import Glibc
import IDL
import IPC
import Node
import Testing

typealias Client = NodeIPC.NodeClient

/// A service publishing a tree, on its own thread.
final class Service: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var thread = pthread_t()
  /// What `ctl` was told.
  var commands: [String] = []
  var counter = 0

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
  }

  func start() {
    pthread_create(&thread, nil, { arg in
      let s = Unmanaged<Service>.fromOpaque(arg!).takeUnretainedValue()
      try? s.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  /// A client of the tree's root.
  func connect() throws -> Client {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return Client(channel: ends.a)
  }

  /// Stops the dispatcher and waits for it.
  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
  }
}

/// The tree most tests use: status and ctl leaves, a data directory, a box
/// clients may create in.
func standard() throws -> Service {
  let s = try Service()
  s.tree.text("status", read: { [s] in "count \(s.counter)\n" })
  s.tree.text("ctl", read: { "" }, write: { [s] command throws(NodeError) in
    guard command.hasPrefix("set ") else { throw .invalid }
    s.commands.append(command)
  })
  s.tree.file("data/hello", Array("hello, world".utf8))
  s.tree.file("data/scratch", [], writable: true)
  s.tree.directory("box", allowsCreate: true)
  s.start()
  return s
}

func remoteError<R>(_ body: () throws(Client.Failure) -> R) -> NodeError? {
  do throws(Client.Failure) {
    _ = try body()
    return nil
  } catch {
    if case .remote(let e) = error { return e }
    return nil
  }
}

@Test func walksStatAndReads() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }

  var status = try root.open("status")
  #expect(try status.readText() == "count 0\n")
  s.counter = 3
  #expect(try status.readText() == "count 3\n")

  let walked = try root.walk(["data", "hello"])
  let qids = walked.qids
  #expect(qids.map(\.kind) == [.directory, .file])
  let helloQid = qids[1]
  var hello = try Client(walked: walked)
  let stat = try hello.stat(NodeIPC.Fields.all)
  #expect(stat.name == "hello" && stat.size == 12 && stat.qid == helloQid && stat.modified > 0)
  #expect(try hello.read(offset: 7, max: 100) == Array("world".utf8))
  #expect(try hello.read(offset: 50, max: 100).isEmpty)

  // A walk that stops early, and walks that fail.
  let partial = try root.walk(["data", "nope", "x"])
  let partialQids = partial.qids
  #expect(partialQids.count == 1)
  let stopped = partial.node == nil
  #expect(stopped)
  #expect(remoteError { () throws(Client.Failure) in try root.walk(["nope"]) } == .notFound)
  #expect(remoteError { () throws(Client.Failure) in try root.walk(["a/b"]) } == .badName)
  #expect(remoteError { () throws(Client.Failure) in try root.walk(Array(repeating: "data", count: 17)) } == .tooManyNames)
  #expect(remoteError { () throws(Client.Failure) in try hello.walk(["x"]) } == .notDirectory)

  // ".." goes up, and stays at the root.
  let up = try root.walk(["data", "..", "..", "status"]).qids
  let statusPath = try status.stat(0).qid.path
  #expect(up.map(\.path) == [qids[0].path, 1, 1, statusPath])

  #expect(remoteError { () throws(Client.Failure) in try root.read(offset: 0, max: 10) } == .isDirectory)
  #expect(remoteError { () throws(Client.Failure) in try hello.readdir(cursor: 0, max: 10, fields: 0) } == .notDirectory)
  _ = consume hello
  _ = consume status
  _ = consume root
}

@Test func ctlAndWrites() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }
  var ctl = try root.open("ctl")
  try ctl.writeText("set latency 64")
  #expect(remoteError { () throws(Client.Failure) in try ctl.writeText("explode") } == .invalid)
  #expect(remoteError { () throws(Client.Failure) in try ctl.write(offset: 0, [0xff]) } == .invalid)
  #expect(s.commands == ["set latency 64"])

  var hello = try root.open("data/hello")
  #expect(remoteError { () throws(Client.Failure) in try hello.write(offset: 0, [1]) } == .unsupported)
  var scratch = try root.open("data/scratch")
  #expect(try scratch.write(offset: 4, Array("abc".utf8)) == 3)
  #expect(try scratch.readAll() == [0, 0, 0, 0] + Array("abc".utf8))
  _ = consume ctl
  _ = consume hello
  _ = consume scratch
  _ = consume root
}

@Test func listingsPageAndDeepPathsOpen() throws {
  let s = try Service()
  for i in 0..<300 { s.tree.file("many/f\(i)", [UInt8(i & 0xff)]) }
  let deep = (0..<40).map { "d\($0)" }.joined(separator: "/")
  s.tree.text(deep + "/leaf", read: { "deep\n" })
  var root = try s.connect()
  s.start()
  defer { s.stop() }

  var many = try root.open("many")
  let first = try many.readdir(cursor: 0, max: 10, fields: NodeIPC.Fields.size)
  #expect(first.entries.map(\.name) == (0..<10).map { "f\($0)" } && first.next == 10 && !first.done)
  #expect(first.entries.allSatisfy { $0.size == 1 && $0.modified == 0 })
  let all = try many.list()
  #expect(all.map(\.name) == (0..<300).map { "f\($0)" })

  // 41 names: three walks of at most 16.
  var leaf = try root.open(deep + "/leaf")
  #expect(try leaf.readText() == "deep\n")
  _ = consume many
  _ = consume leaf
  _ = consume root
}

/// The next change event, or nil within `ms`.
func nextChange(_ c: inout Client, ms: Int64 = 2000) -> NodeIPC.Change? {
  guard let event = try? c.nextEvent(deadline: Clock.monotonic() + ms * 1_000_000) else { return nil }
  guard case .changed(let change) = event else { return nil }
  return change
}

@Test func watchersHearOfChanges() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }

  var box = try root.open("box")
  var watcher = try root.open("box")
  _ = try watcher.watch(since: 0)

  // A client creates a file, writes it, removes it.
  var file = try Client(walked: try box.create("note", kind: .file))
  #expect(nextChange(&watcher).map { $0.kind == .created && $0.name == "note" } == true)
  _ = try file.write(offset: 0, [1, 2, 3])
  #expect(nextChange(&watcher).map { $0.kind == .modified && $0.name == "note" } == true)
  #expect(remoteError { () throws(Client.Failure) in try box.create("note", kind: .file) } == .exists)
  try file.remove()
  #expect(nextChange(&watcher).map { $0.kind == .removed && $0.name == "note" } == true)
  #expect(remoteError { () throws(Client.Failure) in try file.stat(0) } == .notFound)
  #expect(remoteError { () throws(Client.Failure) in try root.create("x", kind: .file) } == .unsupported)

  // The service changes a leaf: its watcher hears.
  var status = try root.open("status")
  let before = try status.watch(since: 0)
  s.counter = 9
  s.tree.touch(s.tree.node("status")!)
  let change = nextChange(&status)
  #expect(change?.kind == .modified && change?.name == "status" && (change?.seq ?? 0) > before)
  #expect(nextChange(&status, ms: 20) == nil)
  _ = consume file
  _ = consume box
  _ = consume watcher
  _ = consume status
  _ = consume root
}

@Test func watchReplaysWhatWasMissedOrSaysItOverflowed() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }
  var status = try root.open("status")
  let start = try status.watch(since: 0)
  _ = consume status
  let leaf = s.tree.node("status")!
  for _ in 0..<3 { s.tree.touch(leaf) }

  // A new watcher asks for what came after `start`: the three changes.
  var again = try root.open("status")
  _ = try again.watch(since: start)
  let replayed = (0..<3).compactMap { _ in nextChange(&again) }
  #expect(replayed.map(\.kind) == [.modified, .modified, .modified])
  #expect(replayed.map(\.seq) == replayed.map(\.seq).sorted() && replayed.first!.seq > start)

  // More changes than the log keeps: an overflow first.
  for _ in 0..<100 { s.tree.touch(leaf) }
  var late = try root.open("status")
  _ = try late.watch(since: start)
  #expect(nextChange(&late)?.kind == .overflow)
  _ = consume again
  _ = consume late
  _ = consume root
}

@Test func closedChannelsLeaveTheDispatcher() throws {
  let s = try standard()
  var root = try s.connect()
  for _ in 0..<50 { _ = try root.open("data/hello") }
  _ = try root.stat(0)
  _ = consume root
  s.stop()
  // Each close queued its packet before the stop's.
  #expect(s.dispatcher.count == 0)
}

// MARK: Generated files stay in step with idlc

@Test func checkedInOutputsMatchIdlc() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/node/NodeTests.swift
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
  let source = "lib/node/Node.swift"
  let interface = try scan([(source, try #require(read(source)))])
  let (library, node) = try #require(interface.protocols.first)
  let regenerate = "regenerate: .build/debug/idlc --c-out lib/node/idl --doc-out lib/node/idl \(source)"
  #expect(cHeader(library, source: source) == read("lib/node/idl/node_ipc.h"), "\(regenerate)")
  #expect(markdown(node, library, source: source) == read("lib/node/idl/Node.md"), "\(regenerate)")
  #expect(Baseline(node, library).text == read("lib/node/idl/todhchai.node.Node.api"))
}
