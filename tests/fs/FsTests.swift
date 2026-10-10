// SPDX-License-Identifier: BSD-3-Clause

// The fs service (N0g): Taisce over a block service session, as Directory
// and File channels that compose Node; attributes, listings, renames,
// queries and live queries, watches, durability through the ring, and the
// service in a hosted boot.

import Block
@testable import Fs
import Glibc
import HostedPrograms
import IDL
import IPC
import Launch
import Node
import Taisce
import Testing

/// A dispatcher on its own thread.
final class Running: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  var thread = pthread_t()

  init() throws {
    dispatcher = try IPCDispatcher()
    pthread_create(&thread, nil, { arg in
      let r = Unmanaged<Running>.fromOpaque(arg!).takeUnretainedValue()
      try? r.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

/// A block service over memory, and an fs service over a session of it.
final class Rig: @unchecked Sendable {
  let memory: MemoryBackend
  let block: Running
  let blockService: BlockService
  let fsThread: Running
  let tree: NodeTree
  let service: FsService

  /// A volume in `memory`: made anew if `format`, else mounted.
  init(_ memory: MemoryBackend = MemoryBackend(blocks: 16384), format: Bool = true) throws {
    self.memory = memory
    block = try Running()
    blockService = BlockService(backend: memory, name: "memory", dispatcher: block.dispatcher)
    let ends = try Channel.create()
    try blockService.serve(ends.b)
    let device = try RingDevice(try BlockClient(ends.a))
    let fs = format
      ? try FileSystem.format(device, label: Array("test".utf8), uuid: [UInt8](repeating: 7, count: 16), now: FsService.now)
      : try FileSystem.mount(device)
    fsThread = try Running()
    tree = NodeTree(dispatcher: fsThread.dispatcher)
    service = try FsService(fs, device: "memory", dispatcher: fsThread.dispatcher)
    service.publish(in: tree)
  }

  /// A Node client of the service's tree at `path`.
  func node(_ path: String = "") throws -> NodeIPC.NodeClient {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    var root = NodeIPC.NodeClient(channel: ends.a)
    return path.isEmpty ? root : try root.open(path)
  }

  /// The volume's root directory.
  func root() throws -> FsIPC.DirectoryClient { FsIPC.DirectoryClient(channel: try node("volume").takeChannel()) }

  func text(_ path: String) throws -> String {
    var c = try node(path)
    return try c.readText()
  }

  func stop() {
    fsThread.stop()
    block.stop()
  }
}

/// What a call's other end threw, if it did.
func remote<E, R: ~Copyable>(_ body: () throws(IPCError<E>) -> R) -> E? {
  do throws(IPCError<E>) {
    _ = try body()
    return nil
  } catch {
    guard case .remote(let e) = error else { return nil }
    return e
  }
}

@Test func filesAndDirectoriesSpeakNodeAndFs() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var root = try rig.root()
  var docs = try root.makeDirectory("docs")
  var note = try docs.makeFile("note.txt")
  let text = Array(String(repeating: "Todhchai ", count: 9000).utf8)  // past one Node message
  try note.write(text)
  #expect(try note.readAll() == text)

  // Through the service's tree, as any Node client (cat, ls) would.
  #expect(try rig.text("volume/docs/note.txt") == String(decoding: text, as: UTF8.self))
  var dir = try rig.node("volume/docs")
  #expect(try dir.list().map(\.name) == ["note.txt"])
  var top = try rig.node("volume")
  let entries = try top.list()
  #expect(entries.map(\.name) == ["docs"] && entries[0].qid.kind == .directory)
  var file = try rig.node("volume/docs/note.txt")
  #expect(try file.stat(NodeIPC.Fields.all).size == UInt64(text.count))
  // A walk past a file stops; ".." climbs, and stays at the volume's root.
  #expect(remote { () throws(NodeIPC.NodeClient.Failure) in try top.open("docs/note.txt/x") } == .notFound)
  #expect(try rig.text("volume/docs/../docs/note.txt").hasPrefix("Todhchai"))
  #expect(try rig.text("volume/../../docs/note.txt").hasPrefix("Todhchai"))

  // Resizing, renaming, removing.
  try note.resize(8)
  #expect(try note.readAll() == Array("Todhchai".utf8))
  try root.rename("docs/note.txt", to: "moved.txt")
  #expect(try root.listAll().map(\.name).sorted() == ["docs", "moved.txt"])
  #expect(remote { () throws(FsIPC.DirectoryClient.NodeFailure) in try root.file("docs/note.txt") } == .notFound)
  var moved = try root.file("moved.txt")
  try moved.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in try c.remove() }
  #expect(try root.listAll().map(\.name) == ["docs"])

  // Errors come back as Node's and fs's.
  #expect(remote { () throws(FsIPC.DirectoryClient.NodeFailure) in try root.makeDirectory("docs") } == .exists)
  #expect(remote { () throws(FsIPC.DirectoryClient.NodeFailure) in try root.makeFile("..") } == .badName)
  _ = try docs.makeFile("keep")
  #expect(remote { () throws(NodeIPC.NodeClient.Failure) in
    try docs.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in try c.remove() }
  } == .notEmpty)
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in try root.rename("nothing", to: "x") } == .notFound)
}

@Test func typedAttributesAndListingsWithThem() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var root = try rig.root()
  var song = try root.makeFile("song.flac")
  try song.setAttribute(.int64("Audio:Year", 1993))
  try song.setAttribute(.string("Audio:Artist", "Clannad"))
  #expect(try song.getAttribute("Audio:Year").int64Value == 1993)
  #expect(try song.getAttribute("Audio:Artist").stringValue == "Clannad")
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in try song.getAttribute("Audio:Album") } == .notFound)
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in
    try song.setAttribute(FsIPC.Attribute(name: "Bad", kind: 2, value: [1]))
  } == .invalid)

  // Node's stat lists them; the batched listing gives those asked for.
  var node = try rig.node("volume/song.flac")
  let names = try node.stat(NodeIPC.Fields.attributes).attributes.map(\.name)
  #expect(names.contains("Audio:Year") && names.contains("Audio:Artist"))
  let listed = try root.listAll(attributes: ["Audio:Year"])
  #expect(listed.count == 1 && listed[0].attributes.map(\.name) == ["Audio:Year"])
  #expect(listed[0].attributes[0].int64Value == 1993 && listed[0].kind == NodeType.file.rawValue)

  try song.removeAttribute("Audio:Year")
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in try song.removeAttribute("Audio:Year") } == .notFound)
}

@Test func queriesAndLiveQueries() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var root = try rig.root()
  var old = try root.makeFile("old.flac")
  try old.setAttribute(.int64("Audio:Year", 1982))
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in try root.query("Audio:Year > 1990", scan: false) } == .needsIndex)
  try root.declareIndex("Audio:Year", kind: 2, caseless: false)
  #expect(try root.indices().contains { $0.name == "Audio:Year" && !$0.building })
  #expect(remote { () throws(IPCError<FsIPC.FsError>) in try root.query("Audio:Year >", scan: false) } == .badQuery)

  // The matches now, then `current`, then changes as they happen.
  var live = FsIPC.LiveQueryClient(channel: try root.live("Audio:Year > 1980", scan: false))
  func next() throws -> FsIPC.QueryChange {
    guard case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else {
      throw IPCError<Never>.wire(.unexpectedMessage)
    }
    return c
  }
  #expect(try next().path == "/old.flac")
  #expect(try next().kind == .current)

  var song = try root.makeFile("song.flac")
  try song.setAttribute(.int64("Audio:Year", 1993))
  let added = try next()
  #expect(added.kind == .added && added.path == "/song.flac")
  try song.setAttribute(.int64("Audio:Year", 1994))
  #expect(try next().kind == .changed)
  try song.setAttribute(.int64("Audio:Year", 1970))
  #expect(try next().kind == .removed)

  #expect(try root.query("Audio:Year < 1990", scan: false).map(\.path).sorted() == ["/old.flac", "/song.flac"])
  #expect(try rig.text("status").contains("live-queries 1\n"))
}

@Test func watchesHearOfChanges() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var root = try rig.root()
  _ = try root.makeFile("first")  // so the journal has begun
  var watcher = try rig.node("volume")
  let seq = try watcher.watch(since: 0)
  #expect(seq > 0)
  _ = try root.makeFile("a")
  guard case .changed(let c) = try watcher.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else {
    Issue.record("no change")
    return
  }
  #expect(c.kind == .created && c.name == "a" && c.seq > seq)

  // A late watcher catches up from a sequence number.
  var late = try rig.node("volume")
  _ = try late.watch(since: seq)
  guard case .changed(let again) = try late.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else {
    Issue.record("no replay")
    return
  }
  #expect(again == c)
}

@Test func whatIsSyncedIsOnTheBlocks() throws {
  let memory = MemoryBackend(blocks: 16384)
  do {
    let rig = try Rig(memory)
    defer { rig.stop() }
    var root = try rig.root()
    var f = try root.makeFile("kept")
    try f.write(Array("through the ring".utf8))
    try f.setAttribute(.string("Test:Note", "yes"))
    try root.sync()
    #expect(try rig.text("status").contains("commits "))
  }
  // Mounted again from the same blocks.
  let rig = try Rig(memory, format: false)
  defer { rig.stop() }
  var root = try rig.root()
  var f = try root.file("kept")
  #expect(try f.readAll() == Array("through the ring".utf8))
  #expect(try f.getAttribute("Test:Note").stringValue == "yes")
  #expect(try rig.text("status").hasPrefix("volume test\ndevice memory\n"))
}

@Test func aGroupCommitsSoonAfterAChange() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var root = try rig.root()
  _ = try root.makeFile("x")
  var committed = false
  for _ in 0..<300 where !committed {
    sleep(until: Clock.monotonic() + 10_000_000)
    committed = try rig.text("status").contains("commits 1\n")
  }
  #expect(committed)
}

/// Writes through /data, which its manifest mounts from fs/volume, and
/// reports in `status`.
let fsUser = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    var data = FsIPC.DirectoryClient(channel: try start.namespace.connect("/data"))
    var f = try data.makeFile("hello.txt")
    try f.write(Array("hello from a hosted process\n".utf8))
    try f.setAttribute(.int64("Audio:Year", 2026))
    var status = try start.namespace.open("/svc/fs/status")
    let fsStatus = try status.readText()
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "wrote hello.txt\n" + fsStatus })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 9)
  }
}

@Test func theServiceInAHostedBoot() throws {
  let image = ".build/test-fs-\(getpid())/block.img"
  defer {
    unlink(image)
    rmdir(".build/test-fs-\(getpid())")
  }
  var programs = hostedPrograms
  programs["user"] = fsUser
  let l = try Launcher(programs: programs, rootJob: try Job.root())
  defer { l.stop() }
  try l.start([
    (path: "block.manifest", text: "service block\nprogram block\narg --create 16M \(image)\nexport\n"),
    (path: "fs.manifest", text: "service fs\nprogram fs\narg --format main /svc/block/device\nuse block\nexport\n"),
    (path: "user.manifest", text: "service user\nprogram user\nuse fs\nmount /data fs/volume\nexport\n"),
  ])
  var user = try l.open("user")
  var status = try user.open("status")
  let text = try status.readText()
  #expect(text.hasPrefix("wrote hello.txt\nvolume main\ndevice /svc/block/device\n"))
  // cat /svc/fs/volume/hello.txt, from outside.
  var fs = try l.open("fs")
  var hello = try fs.open("volume/hello.txt")
  #expect(try hello.readText() == "hello from a hosted process\n")
}

@Test func checkedInOutputsMatchIdlc() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/fs/FsTests.swift
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
  let source = "lib/fs/Fs.swift"
  let interface = try scan([(source, try #require(read(source)))],
                           references: [("lib/node/Node.swift", try #require(read("lib/node/Node.swift")))])
  let library = try #require(interface.libraries.first)
  let regenerate = "regenerate: .build/debug/idlc --c-out lib/fs/idl --doc-out lib/fs/idl --with lib/node/Node.swift \(source)"
  #expect(cHeader(library, source: source) == read("lib/fs/idl/fs_ipc.h"), "\(regenerate)")
  for p in library.protocols {
    let composed = try interface.composedMethods(p, in: library)
    #expect(markdown(p, library, source: source, composed: composed) == read("lib/fs/idl/\(p.name).md"), "\(regenerate)")
    #expect(Baseline(p, library, composed: composed).text == read("lib/fs/idl/\(p.id).api"))
  }
}
