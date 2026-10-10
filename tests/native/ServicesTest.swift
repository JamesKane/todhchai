// SPDX-License-Identifier: BSD-3-Clause

// bin/services-test: N0's services as Embedded Swift on croi (M3c), in one
// process: a Node tree served on a dispatcher thread and read through a
// namespace; then the block service over memory, Taisce's fs service over
// a ring session of it, and a client that makes files with typed
// attributes and sees a live query's update. Run by
// `td boot --test --next bin/services-test`; prints "services-test: ok".

import Block
import BlockRing
import Fs
import IPC
import LibSys
import Node
import Sys
import Taisce

/// A dispatcher on a thread of its own.
final class Running: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  var thread: UInt32 = 0

  init() throws(Status) {
    dispatcher = try IPCDispatcher()
    thread = try Thread.spawn { [dispatcher] in try? dispatcher.run() }.release()
  }

  func stop() {
    dispatcher.stop()
    try? Thread.join(Handle(raw: thread))
    dispatcher.removeAll()
  }
}

@main struct ServicesTest {
  /// The step under way, named when one fails.
  nonisolated(unsafe) static var step: StaticString = "start"

  static func main() {
    do {
      try nodeThroughANamespace()
      try filesWithAttributesAndALiveQuery()
    } catch {
      print("services-test: FAILED at \(step)")
      exit(1)
    }
    print("services-test: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok {
      print("services-test: FAILED: \(what)")
      exit(1)
    }
  }

  static func nodeThroughANamespace() throws {
    step = "dispatcher"
    let running = try Running()
    let tree = NodeTree(dispatcher: running.dispatcher)
    _ = tree.text("status", read: { "dia duit\n" })
    step = "serve"
    let ends = try Channel.create()
    try tree.serve(ends.b)
    step = "mount"
    let ns = Namespace()
    try ns.mount(ends.a, at: "/svc/test", .replace)
    step = "connect"
    var client = NodeIPC.NodeClient(channel: try ns.connect("/svc/test/status"))
    step = "read"
    check(try client.readText() == "dia duit\n", "Node text through the namespace")
    _ = consume client
    running.stop()
    print("services-test: Node ok")
  }

  static func filesWithAttributesAndALiveQuery() throws {
    // The block service over memory, on its own thread.
    step = "block service"
    let blockThread = try Running()
    let memory = MemoryBackend(blocks: 8192)
    let blocks = BlockService(backend: memory, name: "memory", dispatcher: blockThread.dispatcher)
    let ends = try Channel.create()
    try blocks.serve(ends.b)
    step = "block client"
    let client: BlockClient
    do throws(BlockClient.Failure) {
      client = try BlockClient(ends.a)
    } catch {
      switch error {
      case .remote(let e): print("services-test: block client: the service said \(e.rawValue)")
      case .transport(let s): print("services-test: block client: status \(s.rawValue)")
      case .wire: print("services-test: block client: a malformed message")
      }
      throw error
    }
    let device = try RingDevice(client)

    // Taisce over the ring, served by the fs service on a second thread.
    step = "format"
    let fs = try FileSystem.format(device, label: Array("native".utf8), uuid: [UInt8](repeating: 7, count: 16),
                                   now: FsService.now)
    step = "fs service"
    let fsThread = try Running()
    let service = try FsService(fs, device: "memory", dispatcher: fsThread.dispatcher)
    let tree = NodeTree(dispatcher: fsThread.dispatcher)
    service.publish(in: tree)
    let treeEnds = try Channel.create()
    try tree.serve(treeEnds.b)
    var root = NodeIPC.NodeClient(channel: treeEnds.a)
    step = "volume"
    var data = FsIPC.DirectoryClient(channel: try root.open("volume").takeChannel())

    step = "index"
    try data.declareIndex("Audio:Year", kind: 2, caseless: false)
    step = "mkdir"
    var music = try data.makeDirectory("music")
    step = "live query"
    var live = FsIPC.LiveQueryClient(channel: try data.live("Audio:Year >= 1990", scan: false))
    // Up to date with what's there (nothing) before anything is written.
    while case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000), c.kind != .current {}
    for (name, year) in [("Dulaman.flac", Int64(1976)), ("Anam.flac", 1990)] {
      step = "make a song"
      var song = try music.makeFile(name)
      try song.write(Array("\(name)\n".utf8))
      step = "set attributes"
      try song.setAttribute(.string("Audio:Artist", "Clannad"))
      try song.setAttribute(.int64("Audio:Year", year))
    }
    step = "live update"
    var added = ""
    while added.isEmpty, case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) {
      if c.kind == .added { added = c.path }
    }
    check(added.hasSuffix("Anam.flac"), "the live query saw Anam.flac arrive")
    step = "sync"
    try data.sync()

    step = "read back"
    var song = try data.file("music/Anam.flac")
    check(try song.getAttribute("Audio:Year").int64Value == 1990, "the year reads back")
    check(try song.readAll() == Array("Anam.flac\n".utf8), "the file reads back")

    _ = consume song
    _ = consume live
    _ = consume music
    _ = consume data
    _ = consume root
    fsThread.stop()
    blockThread.stop()
    withExtendedLifetime(service) {}
    print("services-test: files, attributes and a live query ok")
  }
}
