// SPDX-License-Identifier: BSD-3-Clause

// The block service (N0f): the ring through the service, requests checked,
// many in flight from several clients, a client that breaks the ring cut
// off, sessions ending with their channels, the image file's cache
// policies, and the service in a hosted boot.

@testable import Block
@testable import BlockRing
import HostedPrograms
import IDL
import Glibc
import IPC
import Launch
import Node
import Testing

/// A block service on its own thread, over `backend`.
final class Disk: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let service: BlockService
  var thread = pthread_t()

  init(_ backend: any BlockBackend) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    service = BlockService(backend: backend, name: "test", dispatcher: dispatcher)
    service.publish(in: tree)
    pthread_create(&thread, nil, { arg in
      let d = Unmanaged<Disk>.fromOpaque(arg!).takeUnretainedValue()
      try? d.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  /// A client of the tree's root.
  func root() throws -> NodeIPC.NodeClient {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return NodeIPC.NodeClient(channel: ends.a)
  }

  /// A session, through a walk to `device`.
  func client(entries: Int = 64, bufferBlocks: Int = 256) throws -> BlockClient {
    var r = try root()
    return try BlockClient(try r.open("device").takeChannel(), entries: entries, bufferBlocks: bufferBlocks)
  }

  func status() throws -> String {
    var r = try root()
    var s = try r.open("status")
    return try s.readText()
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

func blocks(_ n: Int, seed: UInt8) -> [UInt8] { (0..<n * 4096).map { UInt8(truncatingIfNeeded: $0 / 7) &+ seed } }

/// What a request completes with.
func outcome(_ c: inout BlockClient, _ s: Submission) throws -> BlockStatus {
  let submitted = c.submit(s)
  #expect(submitted)
  c.publish()
  let done = try #require(try c.wait(deadline: Clock.monotonic() + 2_000_000_000))
  #expect(done.tag == s.tag)
  return done.status
}

/// The error a call's other end sent back, if it did.
func remote<E, R: ~Copyable>(_ body: () throws(IPCError<E>) -> R) -> E? {
  do throws(IPCError<E>) {
    _ = try body()
    return nil
  } catch {
    guard case .remote(let e) = error else { return nil }
    return e
  }
}

/// Polls `condition` for up to 2 s.
func eventually(_ condition: () throws -> Bool) rethrows -> Bool {
  for _ in 0..<400 {
    if try condition() { return true }
    sleep(until: Clock.monotonic() + 5_000_000)
  }
  return false
}

@Test func readWriteAndFlushThroughTheRing() throws {
  let memory = MemoryBackend(blocks: 1024)
  let disk = try Disk(memory)
  defer { disk.stop() }
  var c = try disk.client(bufferBlocks: 16)
  #expect(c.info == BlockIPC.DeviceInfo(blockSize: 4096, blockCount: 1024, maxTransfer: 256, readOnly: false))

  // 40 blocks: three requests through a 16-block buffer.
  let data = blocks(40, seed: 3)
  try c.write(100, data)
  #expect(Array(memory.bytes[100 * 4096..<140 * 4096]) == data)
  #expect(try c.read(100, count: 40) == data)
  #expect(try c.read(99, count: 1) == [UInt8](repeating: 0, count: 4096))
  try c.write(1023, blocks(1, seed: 9), policy: .uncached)
  #expect(try c.read(1023, count: 1, policy: .readOnce) == blocks(1, seed: 9))
  try c.flush()
  #expect(memory.flushes == 1)

  let status = try disk.status()
  #expect(status.contains("blocks 1024\n") && status.contains("sessions 1\n"))
  #expect(status.contains("writes 4 blocks 41\n") && status.contains("reads 5 blocks 42\n"))
  #expect(status.contains("flushes 1\n") && status.contains("errors 0\n"))

  // `device` is a service node: listed as one, and not a Node channel.
  var root = try disk.root()
  let entries = try root.list()
  #expect(entries.first { $0.name == "device" }?.qid.kind == .service)
  #expect(entries.first { $0.name == "status" }?.qid.kind == .file)
  #expect(remote { () throws(NodeIPC.NodeClient.Failure) in try root.open("device/x") } == .notFound)
}

@Test func requestsAreChecked() throws {
  let disk = try Disk(MemoryBackend(blocks: 64))
  defer { disk.stop() }
  var c = try disk.client(bufferBlocks: 4)
  let buffer = c.bufferID
  func run(_ s: Submission) throws -> BlockStatus { try outcome(&c, s) }

  #expect(try run(Submission(.read, buffer: buffer, tag: 1, block: 0, count: 4)) == .ok)
  #expect(try run(Submission(.read, buffer: buffer, tag: 2, block: 0, count: 0)) == .invalid)
  #expect(try run(Submission(.read, buffer: buffer, tag: 3, block: 63, count: 2)) == .outOfRange)
  #expect(try run(Submission(.read, buffer: buffer, tag: 4, block: .max, count: 1)) == .outOfRange)
  #expect(try run(Submission(.read, buffer: buffer, tag: 5, block: 0, count: 257)) == .outOfRange)
  #expect(try run(Submission(.read, buffer: 77, tag: 6, block: 0, count: 1)) == .badBuffer)
  #expect(try run(Submission(.read, buffer: buffer, tag: 7, block: 0, count: 2, bufferBlock: 3)) == .badBuffer)
  #expect(try run(Submission(.write, policy: .readOnce, buffer: buffer, tag: 8, block: 0, count: 1)) == .invalid)
  #expect(try run(Submission(.flush, policy: .uncached, tag: 9)) == .invalid)

  // An entry that isn't a request: an unknown operation, then nonzero
  // reserved bytes. Its tag still comes back.
  for (offset, value) in [(0, 9 as UInt8), (2, 1)] {
    let s = Submission(.read, buffer: buffer, tag: 10, block: 0, count: 1)
    let submitted = c.submit(s)
    #expect(submitted)
    let at = c.ring.memory.submissionOffset(c.ring.submitted &- 1)
    c.ring.memory.put(value, at + offset)
    c.publish()
    let done = try #require(try c.wait(deadline: Clock.monotonic() + 2_000_000_000))
    #expect(done == Completion(tag: 10, status: .invalid))
  }

  // Detached buffers are gone; others can be attached.
  try c.device.detach(buffer)
  #expect(remote { () throws(BlockClient.Failure) in try c.device.detach(buffer) } == .notFound)
  #expect(try run(Submission(.read, buffer: buffer, tag: 11, block: 0, count: 1)) == .badBuffer)
  let other = try c.attach(try VMO.create(size: 4096))
  #expect(try run(Submission(.read, buffer: other, tag: 12, block: 0, count: 1)) == .ok)
  #expect(remote { () throws(BlockClient.Failure) in try c.device.open(entries: 8) } == .alreadyOpen)
  #expect(try disk.status().contains("errors 11\n"))

  // A read-only device refuses writes.
  let readOnly = try Disk(MemoryBackend(blocks: 8, readOnly: true))
  defer { readOnly.stop() }
  var r = try readOnly.client(bufferBlocks: 1)
  #expect(throws: BlockStatus.readOnly) { try r.write(0, blocks(1, seed: 0)) }
  #expect(try r.read(0, count: 1).count == 4096)

  // Bad ring sizes.
  var root = try disk.root()
  var device = BlockIPC.DeviceClient(channel: try root.open("device").takeChannel())
  for entries: UInt32 in [0, 3, 8192] {
    #expect(remote { () throws(BlockClient.Failure) in try device.open(entries: entries) } == .invalid)
  }
}

@Test func manyInFlightFromSeveralClients() throws {
  let memory = MemoryBackend(blocks: 4096)
  let disk = try Disk(memory)
  defer { disk.stop() }

  // Each client owns 512 blocks; it writes them all with 64 in flight, a
  // block each, round a 16-entry ring, then reads them back the same way.
  final class Result: @unchecked Sendable { var failures: [String] = [] }
  let result = Result()
  let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  pthread_mutex_init(lock, nil)
  func fail(_ s: String) {
    pthread_mutex_lock(lock)
    result.failures.append(s)
    pthread_mutex_unlock(lock)
  }

  struct Job { let disk: Disk; let index: Int; let fail: (String) -> Void }
  var threads: [pthread_t] = []
  for i in 0..<4 {
    let job = Unmanaged.passRetained(Box(Job(disk: disk, index: i, fail: fail)))
    var t = pthread_t()
    pthread_create(&t, nil, { arg in
      let job = Unmanaged<Box<Job>>.fromOpaque(arg!).takeRetainedValue().value
      do {
        var c = try job.disk.client(entries: 16, bufferBlocks: 512)
        let first = UInt64(job.index * 512)
        let size = 4096
        for write in [true, false] {
          if write {
            for b in 0..<512 { c.buffer.address.storeBytes(of: UInt64(first) + UInt64(b), toByteOffset: b * size, as: UInt64.self) }
          } else {
            c.buffer.address.initializeMemory(as: UInt8.self, repeating: 0, count: 512 * size)
          }
          var next = 0, done = 0
          while done < 512 {
            while next < 512, c.ring.inFlight < 16 {
              _ = c.submit(Submission(write ? .write : .read, buffer: c.bufferID, tag: UInt64(next),
                                      block: first + UInt64(next), count: 1, bufferBlock: UInt32(next)))
              next += 1
            }
            c.publish()
            guard let comp = try c.wait(deadline: Clock.monotonic() + 5_000_000_000), comp.status == .ok else {
              job.fail("client \(job.index): a request failed or timed out")
              return nil
            }
            done += 1
          }
        }
        for b in 0..<512 where c.buffer.address.load(fromByteOffset: b * size, as: UInt64.self) != first + UInt64(b) {
          job.fail("client \(job.index): block \(b) read back wrong")
          break
        }
      } catch {
        job.fail("client \(job.index): \(error)")
      }
      return nil
    }, job.toOpaque())
    threads.append(t)
  }
  for t in threads { pthread_join(t, nil) }
  #expect(result.failures == [])
  for b in 0..<2048 {
    let value = memory.bytes.withUnsafeBytes { $0.load(fromByteOffset: b * 4096, as: UInt64.self) }
    if value != UInt64(b) {
      Issue.record("block \(b) holds \(value)")
      break
    }
  }
  #expect(try disk.status().contains("writes 2048 blocks 2048\n"))
}

final class Box<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
}

@Test func aClientThatBreaksTheRingIsCutOff() throws {
  let disk = try Disk(MemoryBackend(blocks: 8))
  defer { disk.stop() }
  var c = try disk.client(entries: 4, bufferBlocks: 1)
  // The tail claims a thousand requests in a ring of four.
  c.ring.memory.store(1000, BlockRing.submissionTail)
  try c.signal.signalPeer(set: BlockRing.kick)
  #expect(throws: BlockStatus.io) { _ = try c.wait(deadline: Clock.monotonic() + 2_000_000_000) }
  #expect(try disk.status().contains("corrupt 1\n"))
  // The channel still answers; the session holds no ring now.
  #expect(try c.device.info().blockCount == 8)
}

@Test func sessionsEndWithTheirChannels() throws {
  let disk = try Disk(MemoryBackend(blocks: 8))
  defer { disk.stop() }
  do {
    var a = try disk.client(), b = try disk.client()
    try a.write(0, blocks(1, seed: 1))
    #expect(try b.read(0, count: 1) == blocks(1, seed: 1))
    #expect(try disk.status().contains("sessions 2\n"))
  }
  #expect(try eventually { try disk.status().contains("sessions 0\n") })
}

@Test func anImageFileWithEachPolicy() throws {
  let path = ".build/test-block-\(getpid()).img"
  defer { unlink(path) }
  let backend = try FileBackend(path: path, blocks: 256)
  let disk = try Disk(backend)
  defer { disk.stop() }
  var c = try disk.client(bufferBlocks: 8)
  #expect(c.info.blockCount == 256)

  let policies: [CachePolicy] = [.cached, .uncached]
  for (i, policy) in policies.enumerated() {
    let data = blocks(20, seed: UInt8(i))
    try c.write(UInt64(i * 20), data, policy: policy)
    for read in [CachePolicy.cached, .uncached, .readOnce] {
      #expect(try c.read(UInt64(i * 20), count: 20, policy: read) == data, "written \(policy), read \(read)")
    }
  }
  try c.flush()

  // The file holds it, read past the service.
  let fd = open(path, O_RDONLY)
  defer { close(fd) }
  var bytes = [UInt8](repeating: 0, count: 40 * 4096)
  #expect(bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) } == 40 * 4096)
  #expect(bytes == blocks(20, seed: 0) + blocks(20, seed: 1))

  // Read-only, it refuses writes; reopened, the size comes from the file.
  let again = try FileBackend(path: path, readOnly: true)
  #expect(again.blockCount == 256 && again.readOnly)
  var buffer = [UInt8](repeating: 0, count: 4096)
  #expect(buffer.withUnsafeMutableBytes { again.read(20, into: $0, policy: .readOnce) } == .ok)
  #expect(buffer == blocks(1, seed: 1))
}

/// Uses /svc/block from inside a hosted process: writes, reads back and
/// reports in `status`.
let blockUser = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    var c = try BlockClient(try start.namespace.connect("/svc/block/device"), bufferBlocks: 4)
    try c.write(3, blocks(2, seed: 7), policy: .uncached)
    try c.flush()
    let ok = try c.read(3, count: 2) == blocks(2, seed: 7)
    var status = try start.namespace.open("/svc/block/status")
    let text = try status.readText()
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "round trip \(ok ? "ok" : "wrong")\n" + text })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 9)
  }
}

@Test func theServiceInAHostedBoot() throws {
  let image = ".build/test-hosted-\(getpid())/block.img"
  defer {
    unlink(image)
    rmdir(".build/test-hosted-\(getpid())")
  }
  let blockProgram = try #require(hostedPrograms.first { $0.name == "block" }).entry
  let l = try Launcher(programs: [("block", blockProgram), ("user", blockUser)], rootJob: try Job.root())
  defer { l.stop() }
  try l.start([
    (path: "block.manifest", text: "service block\nprogram block\narg --create 1M \(image)\nexport\n"),
    (path: "user.manifest", text: "service user\nprogram user\nuse block\nexport\n"),
  ])
  var root = try l.open("user")
  var status = try root.open("status")
  let text = try status.readText()
  #expect(text.hasPrefix("round trip ok\n"))
  #expect(text.contains("device \(image)\n") && text.contains("blocks 256\n"))
  #expect(text.contains("writes 1 blocks 2\n") && text.contains("flushes 1\n"))
}

@Test func checkedInOutputsMatchIdlc() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/block/BlockTests.swift
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
  let source = "lib/block/Block.swift"
  let text = try #require(read(source))
  let (library, p) = try #require(try scan([(source, text)]).protocols.first)
  let regenerate = "regenerate: .build/debug/idlc --c-out lib/block/idl --doc-out lib/block/idl \(source)"
  #expect(cHeader(library, source: source) == read("lib/block/idl/block_ipc.h"), "\(regenerate)")
  #expect(markdown(p, library, source: source) == read("lib/block/idl/Device.md"), "\(regenerate)")
  #expect(Baseline(p, library).text == read("lib/block/idl/\(p.id).api"))
}
