// SPDX-License-Identifier: BSD-3-Clause

// n0-bench: N0's budgets (docs/milestones/N0.md, the exit), measured on
// the host from trace zones and IPC flows, ahead of M3's numbers on croi:
//
//   Node.stat          a channel call's round trip: its flow, from the
//                      call's write to its reply's read (four steps: the
//                      write, the server's read, the reply, the read)
//   node.walk_read     open a leaf two names down a Node tree and read it
//   block.read4k       a 4 KiB block read through the block ring
//   fs.live            a matching attribute write through the fs service,
//                      then the live query's update that reports it
//                      (M3's target: 1 ms)
//   launch.ready       the launcher starting a service until it is ready
//
//   swift build -c release --product n0-bench
//   .build/debug/td trace record -o DIR -c app,ipc,mark -- .build/release/n0-bench

import Block
import Fs
import Glibc
import IPC
import Launch
import Node
import Taisce
import Trace

enum Names {
  static let walkRead = TraceName("node.walk_read")
  static let read4k = TraceName("block.read4k")
  static let live = TraceName("fs.live")
  static let launch = TraceName("launch.ready")
}

/// A dispatcher on a thread of its own.
final class Running: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  var thread = pthread_t()

  init() throws {
    dispatcher = try IPCDispatcher()
    pthread_create(&thread, nil, { arg in
      try? Unmanaged<Running>.fromOpaque(arg!).takeUnretainedValue().dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

func fail(_ message: String) -> Never {
  let line = Array("n0-bench: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
  exit(1)
}

/// A service that serves a small tree and says it's ready.
let treeProgram = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "ready\n" })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

let rounds = 2000
_ = Trace.startFromEnvironment()
do {
  // A Node tree, served on its own thread.
  let nodes = try Running()
  let tree = NodeTree(dispatcher: nodes.dispatcher)
  tree.text("status", read: { "ok\n" })
  tree.file("dir/leaf", (0..<4096).map { UInt8(truncatingIfNeeded: $0) })
  let ends = try Channel.create()
  try tree.serve(ends.b)
  var root = NodeIPC.NodeClient(channel: ends.a)
  var status = try root.open("status")

  Trace.mark("calls")
  for _ in 0..<rounds { _ = try status.stat(0) }
  Trace.mark("walks")
  for _ in 0..<rounds {
    let start = Trace.now()
    var leaf = try root.open("dir/leaf")
    let bytes = try leaf.read(offset: 0, max: 4096)
    Trace.zone(Names.walkRead, since: start)
    if bytes.count != 4096 { fail("read \(bytes.count) bytes") }
  }
  nodes.stop()

  // The block ring, over memory.
  Trace.mark("blocks")
  let memory = MemoryBackend(blocks: 16384)
  let blocks = try Running()
  let blockService = BlockService(backend: memory, name: "memory", dispatcher: blocks.dispatcher)
  let blockEnds = try Channel.create()
  try blockService.serve(blockEnds.b)
  var disk = try BlockClient(blockEnds.a, bufferBlocks: 1)
  for i in 0..<rounds {
    let start = Trace.now()
    _ = try disk.read(UInt64(i % 16384), count: 1)
    Trace.zone(Names.read4k, since: start)
  }

  // A live query's update through the fs service, over another session.
  Trace.mark("live")
  let fsEnds = try Channel.create()
  try blockService.serve(fsEnds.b)
  let fs = try FileSystem.format(try RingDevice(try BlockClient(fsEnds.a)), label: Array("bench".utf8),
                                 uuid: [UInt8](repeating: 7, count: 16), now: FsService.now)
  let files = try Running()
  let fsTree = NodeTree(dispatcher: files.dispatcher)
  let fsService = try FsService(fs, device: "memory", dispatcher: files.dispatcher)
  fsService.publish(in: fsTree)
  let fsRoot = try Channel.create()
  try fsTree.serve(fsRoot.b)
  var top = NodeIPC.NodeClient(channel: fsRoot.a)
  var volume = FsIPC.DirectoryClient(channel: try top.open("volume").takeChannel())
  try volume.declareIndex("Bench:N", kind: 2, caseless: false)
  var song = try volume.makeFile("song")
  var live = FsIPC.LiveQueryClient(channel: try volume.live("Bench:N > 0", scan: false))
  while case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000), c.kind != .current {}
  for i in 0..<500 {
    let start = Trace.now()
    // Alternately in and out of the query's matches: each write is reported.
    try song.setAttribute(.int64("Bench:N", i % 2 == 0 ? 1 : 0))
    guard case .changed = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else { fail("no update") }
    Trace.zone(Names.live, since: start)
  }
  files.stop()
  blocks.stop()
  withExtendedLifetime((blockService, fsService)) {}

  // Launch to ready, a service at a time.
  Trace.mark("launches")
  for _ in 0..<100 {
    let l = try Launcher(programs: ["tree": treeProgram], rootJob: try Job.root())
    let start = Trace.now()
    try l.start([(path: "tree.manifest", text: "service tree\nprogram tree\nexport\n")])
    Trace.zone(Names.launch, since: start)
    l.stop()
  }
  Trace.mark("end")
} catch {
  fail("\(error)")
}
Trace.stop()
