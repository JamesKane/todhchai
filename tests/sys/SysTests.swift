// SPDX-License-Identifier: BSD-3-Clause

// Sys over the hosted kernel: each object kind, rights, and processes with
// their own handle tables (N0a).

import Glibc
import Sys
import Testing

/// The status `body` throws, or `.ok`.
func statusOf<R>(_ body: () throws(Status) -> R) -> Status {
  do throws(Status) {
    _ = try body()
    return .ok
  } catch {
    return error
  }
}

let second: Int64 = 1_000_000_000
func soon(_ ms: Int64 = 2000) -> Int64 { Clock.monotonic() + ms * 1_000_000 }

// MARK: Handles and rights

@Test func duplicateAndReplaceNarrowRights() throws {
  let event = try Event.create()
  let reader = try event.duplicate([.wait, .transfer])
  #expect(try reader.info().rights == [.wait, .transfer])
  #expect(statusOf { () throws(Status) in try reader.signal(set: Signals.signaled) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try reader.duplicate() } == .accessDenied)
  #expect(statusOf { () throws(Status) in try event.duplicate([.wait, .manageJob]) } == .invalidArgs)

  let narrowed = try event.replace([.signal, .wait])
  try narrowed.signal(set: Signals.signaled)
  #expect(try reader.wait(for: Signals.signaled, deadline: 0) & Signals.signaled != 0)
}

@Test func rightsTravelWithTheHandle() throws {
  let ends = try Channel.create()
  let a = ends.a, b = ends.b
  let event = try Event.create()
  let waitOnly = try event.duplicate([.wait, .transfer])
  try Channel.write(a, bytes: [0, 0, 0, 0], handles: [waitOnly.release()])
  let moved = Handle(raw: try Channel.read(b).handles[0])
  #expect(try moved.info().rights == [.wait, .transfer])

  // Without TRANSFER a handle can't move, and the write consumes it anyway.
  let fixed = try event.duplicate([.wait])
  let raw = fixed.release()
  #expect(statusOf { () throws(Status) in try Channel.write(a, bytes: [], handles: [raw]) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try Kernel_info(raw) } == .badHandle)
}

func Kernel_info(_ raw: UInt32) throws(Status) -> HandleInfo {
  try lending(raw) { (h: borrowing Handle) throws(Status) in try h.info() }
}

/// Lends a raw handle the caller still owns to `body` as a `Handle`.
func lending<R, E: Error>(_ raw: UInt32, _ body: (borrowing Handle) throws(E) -> R) throws(E) -> R {
  let h = Handle(raw: raw)
  do throws(E) {
    let r = try body(h)
    _ = h.release()
    return r
  } catch {
    _ = h.release()
    throw error
  }
}

@Test func infoGivesKoidsTypesAndPeers() throws {
  let ends = try Channel.create()
  let a = try ends.a.info(), b = try ends.b.info()
  #expect(a.type == ObjectType.channel && b.type == ObjectType.channel)
  #expect(a.relatedKoid == b.koid && b.relatedKoid == a.koid)
  #expect(a.rights == .channelDefault)
  let pair = try EventPair.create()
  let p = try pair.a.info()
  let q = try pair.b.info()
  #expect(p.type == ObjectType.eventPair && p.relatedKoid == q.koid)
  #expect(try Event.create().info().relatedKoid == 0)
}

@Test func flowIDsAreCroisSplitmix() {
  // Reference values from an independent splitmix64 (croi's croi_flow_id).
  #expect(flowID(channel: 1024, txid: 1) == 0x9d61_a03a_3cfc_0647)
  #expect(flowID(channel: 0, txid: 0) == 0)
  #expect(flowID(channel: UInt64.max, txid: UInt32.max) == 0xd940_3093_1f5c_bbca)
}

// MARK: Eventpairs and peer signals

@Test func eventPairSignalsItsPeerAndSeesItClose() throws {
  let pair = try EventPair.create()
  var a: Handle? = pair.a
  let b = pair.b
  try a!.signalPeer(set: Signals.signaled | (1 << 24))
  #expect(try b.wait(for: Signals.signaled, deadline: 0) == Signals.signaled | (1 << 24))
  #expect(statusOf { () throws(Status) in try a!.signalPeer(set: Signals.peerClosed) } == .invalidArgs)
  a = nil
  #expect(try b.wait(for: Signals.peerClosed, deadline: 0) & Signals.peerClosed != 0)
  #expect(statusOf { () throws(Status) in try b.signalPeer(set: Signals.signaled) } == .peerClosed)
}

// MARK: Channel calls

/// Serves `count` calls on `end` from another thread: each reply is the
/// request's bytes with every byte after the txid incremented.
func serve(_ end: consuming Handle, count: Int, delayMs: Int64 = 0) -> pthread_t {
  final class Box: @unchecked Sendable {
    let raw: UInt32
    let count: Int
    let delay: Int64
    init(_ raw: UInt32, _ count: Int, _ delay: Int64) {
      self.raw = raw
      self.count = count
      self.delay = delay
    }
  }
  let box = Unmanaged.passRetained(Box(end.release(), count, delayMs)).toOpaque()
  var thread = pthread_t()
  pthread_create(&thread, nil, { arg in
    let box = Unmanaged<Box>.fromOpaque(arg!).takeRetainedValue()
    let end = Handle(raw: box.raw)
    for _ in 0..<box.count {
      guard (try? end.wait(for: Signals.readable | Signals.peerClosed)) != nil,
            let m = try? Channel.read(end) else { break }
      if box.delay > 0 { sleep(until: Clock.monotonic() + box.delay * 1_000_000) }
      var reply = m.bytes
      for i in 4..<reply.count { reply[i] &+= 1 }
      try? Channel.write(end, bytes: reply, handles: m.handles)
    }
    return nil
  }, box)
  return thread
}

@Test func callGetsItsOwnReply() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 3)
  for n in UInt8(1)...3 {
    let event = try Event.create()
    let reply = try Channel.call(client, bytes: [0, 0, 0, 0, n, n], handles: [event.release()], deadline: soon())
    #expect(reply.bytes.count == 6)
    #expect(reply.bytes[4...] == [n + 1, n + 1])
    #expect(reply.bytes[3] & 0x80 != 0)  // the kernel's txids have the high bit
    #expect(reply.handles.count == 1)
    close(raw: reply.handles[0])
  }
  pthread_join(server, nil)
}

@Test func callsFromManyThreadsEachGetTheirReply() throws {
  let ends = try Channel.create()
  let raw = ends.a.release()
  let server = serve(ends.b, count: 64)
  final class Failures: @unchecked Sendable { var count = 0; var lock = pthread_mutex_t() }
  let failures = Failures()
  pthread_mutex_init(&failures.lock, nil)
  DispatchlessParallel.run(8) { worker in
    lending(raw) { (c: borrowing Handle) in
      for i in 0..<8 {
        let tag = UInt8(worker * 8 + i)
        let ok = (try? Channel.call(c, bytes: [0, 0, 0, 0, tag], deadline: soon()))?.bytes.last == tag &+ 1
        if !ok {
          pthread_mutex_lock(&failures.lock)
          failures.count += 1
          pthread_mutex_unlock(&failures.lock)
        }
      }
    }
  }
  #expect(failures.count == 0)
  close(raw: raw)
  pthread_join(server, nil)
}

@Test func callTimesOutAndALateReplyIsDropped() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 2, delayMs: 50)
  #expect(statusOf { () throws(Status) in
    try Channel.call(client, bytes: [0, 0, 0, 0, 7], deadline: Clock.monotonic() + 5_000_000)
  } == .timedOut)
  // The first reply arrives after the call gave up: it lands on the
  // channel as an ordinary message, not in the next call.
  let reply = try Channel.call(client, bytes: [0, 0, 0, 0, 9], deadline: soon())
  #expect(reply.bytes.last == 10)
  pthread_join(server, nil)
  #expect(try Channel.read(client).bytes.last == 8)
}

@Test func callSeesThePeerClose() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 0)  // closes its end at once
  pthread_join(server, nil)
  #expect(statusOf { () throws(Status) in try Channel.call(client, bytes: [0, 0, 0, 0], deadline: soon()) }
    == .peerClosed)
}

// MARK: Ports

@Test func waitAsyncQueuesAPacketOnce() throws {
  let port = try Port.create()
  let event = try Event.create()
  try event.waitAsync(port: port, key: 42, signals: Signals.signaled)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  try event.signal(set: Signals.signaled)
  let packet = try Port.wait(port, deadline: 0)
  #expect(packet.key == 42 && packet.type == 1)
  #expect(packet.trigger == Signals.signaled && packet.observed == Signals.signaled)
  // One shot: it doesn't fire again.
  try event.signal(clear: Signals.signaled, set: 0)
  try event.signal(set: Signals.signaled)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
}

@Test func levelWaitFiresAtOnceAndEdgeWaitsForAChange() throws {
  let port = try Port.create()
  let event = try Event.create()
  try event.signal(set: Signals.signaled)
  try event.waitAsync(port: port, key: 1, signals: Signals.signaled)
  try event.waitAsync(port: port, key: 2, signals: Signals.signaled, edge: true)
  #expect(try Port.wait(port, deadline: 0).key == 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  try event.signal(clear: Signals.signaled, set: 0)
  try event.signal(set: Signals.signaled)
  #expect(try Port.wait(port, deadline: 0).key == 2)
}

@Test func userPacketsAndCancel() throws {
  let port = try Port.create()
  try Port.queue(port, Packet(key: 5, payload: (1, 2, 3, 4)))
  let p = try Port.wait(port, deadline: 0)
  #expect(p.key == 5 && p.type == 0 && p.payload.3 == 4)

  let event = try Event.create()
  try event.waitAsync(port: port, key: 6, signals: Signals.signaled)
  try Port.cancel(port, source: event, key: 6)
  try event.signal(set: Signals.signaled)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  #expect(statusOf { () throws(Status) in try Port.cancel(port, source: event, key: 6) } == .notFound)
}

@Test func closingTheWatchedHandleCancelsItsWait() throws {
  let port = try Port.create()
  let event = try Event.create()
  let other = try event.duplicate()
  var watched: Handle? = try event.duplicate()
  try watched!.waitAsync(port: port, key: 3, signals: Signals.signaled)
  watched = nil
  try other.signal(set: Signals.signaled)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
}

@Test func portWakesAWaitingThread() throws {
  let port = try Port.create()
  let channel = try Channel.create()
  try channel.b.waitAsync(port: port, key: 9, signals: Signals.readable)
  let raw = channel.a.release()  // channels can't be duplicated
  var t = pthread_t()
  pthread_create(&t, nil, { arg in
    let a = Handle(raw: UInt32(UInt(bitPattern: arg)))
    sleep(until: Clock.monotonic() + 10_000_000)
    try? Channel.write(a, bytes: [1])
    return nil
  }, UnsafeMutableRawPointer(bitPattern: UInt(raw)))
  let packet = try Port.wait(port, deadline: soon())
  #expect(packet.key == 9 && packet.trigger == Signals.readable)
  pthread_join(t, nil)
}

// MARK: VMOs

@Test func vmoReadWriteMapAndRights() throws {
  let vmo = try VMO.create(size: 5000)
  #expect(try VMO.size(vmo) == 8192)
  try VMO.write(vmo, offset: 4090, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  #expect(try VMO.read(vmo, offset: 4090, count: 10) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  #expect(statusOf { () throws(Status) in try VMO.read(vmo, offset: 8190, count: 3) } == .outOfRange)

  let shared = try vmo.duplicate()
  do {
    let a = try VMO.map(vmo, length: 8192)
    let b = try VMO.map(shared, offset: 4096, length: 4096)
    a.store(UInt64(0x1122_3344_5566_7788), at: 4096 + 16)
    #expect(b.load(UInt64.self, at: 16) == 0x1122_3344_5566_7788)
    #expect(b.load(UInt8.self, at: 0) == 7)
  }
  #expect(try VMO.read(shared, offset: 4096 + 16, count: 1) == [0x88])

  let readOnly = try vmo.duplicate([.read, .map])
  #expect(statusOf { () throws(Status) in try VMO.write(readOnly, offset: 0, [1]) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try VMO.map(readOnly, length: 4096, writable: true) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try VMO.map(readOnly, length: 4096, writable: false) } == .ok)
  #expect(statusOf { () throws(Status) in try VMO.map(vmo, offset: 100, length: 4096) } == .outOfRange)
}

@Test func aMappingKeepsTheVMO() throws {
  var vmo: Handle? = try VMO.create(size: 4096)
  let mapping = try VMO.map(vmo!, length: 4096)
  vmo = nil
  mapping.store(UInt32(77), at: 0)
  #expect(mapping.load(UInt32.self, at: 0) == 77)
}

// MARK: Timers

@Test func timerFiresAtItsDeadline() throws {
  let timer = try Timer.create()
  let start = Clock.monotonic()
  try Timer.set(timer, deadline: start + 20_000_000)
  #expect(try timer.wait(for: Signals.signaled, deadline: start + 5 * second) & Signals.signaled != 0)
  #expect(Clock.monotonic() - start >= 20_000_000)
}

@Test func cancelledTimerNeverFires() throws {
  let timer = try Timer.create()
  try Timer.set(timer, deadline: Clock.monotonic() + 10_000_000)
  try Timer.cancel(timer)
  #expect(statusOf { () throws(Status) in
    try timer.wait(for: Signals.signaled, deadline: Clock.monotonic() + 40_000_000)
  } == .timedOut)
}

@Test func timerWakesAPort() throws {
  let port = try Port.create()
  let timer = try Timer.create()
  try timer.waitAsync(port: port, key: 12, signals: Signals.signaled)
  try Timer.set(timer, deadline: Clock.monotonic() + 5_000_000)
  #expect(try Port.wait(port, deadline: soon()).key == 12)
}

// MARK: Jobs, processes, threads

/// What a hosted process reports back: a channel its entry writes to.
struct Spawned: ~Copyable {
  var process: Handle
  var report: Handle
}

func spawn(_ job: borrowing Handle, _ name: String, _ entry: ProgramEntry) throws -> Spawned {
  let process = try Process.create(job: job, name: name)
  let ends = try Channel.create()
  let report = ends.a
  _ = try Process.start(process, entry: entry, arg: ends.b)
  return Spawned(process: process, report: report)
}

@Test func aProcessHasItsOwnHandleTable() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let mine = try Event.create()
  let mineRaw = mine.raw
  let spawned = try spawn(job, "isolated", ProgramEntry { startup in
    // The host's handle number means nothing here.
    let foreign = Handle(raw: mineRaw)
    let status = statusOf { () throws(Status) in try foreign.info() }
    _ = foreign.release()
    // Its own handles work.
    let event = try? Event.create()
    let ok: UInt8 = (try? event?.info()) != nil ? 1 : 0
    try? Channel.write(startup, bytes: [UInt8(truncatingIfNeeded: -status.rawValue), ok])
    Process.exit(code: 3)
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  #expect(try Channel.read(report).bytes == [UInt8(-Status.badHandle.rawValue), 1])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
  let info = try Process.info(process)
  #expect(info.exited && info.started && info.returnCode == 3)
  // Its handles closed when it ended, the startup channel's end among them.
  #expect(try report.wait(for: Signals.peerClosed, deadline: soon()) & Signals.peerClosed != 0)
}

@Test func aProcessEndsWithItsLastThread() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let spawned = try spawn(job, "threads", ProgramEntry { startup in
    let ends = try! Channel.create()
    let raw = ends.a.release()
    var keep: Handle? = ends.b
    // A second thread, which outlives the first.
    let pair = try! EventPair.create()
    _ = pair
    try? Channel.write(startup, bytes: [1], handles: [raw])
    _ = try? keep!.wait(for: Signals.readable, deadline: soon())
    keep = nil
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  let m = try Channel.read(report)
  let go = Handle(raw: m.handles[0])
  // Still running: its thread waits for us.
  #expect(statusOf { () throws(Status) in try process.wait(for: Signals.terminated, deadline: 0) } == .timedOut)
  try Channel.write(go, bytes: [2])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
  #expect(try Process.info(process).returnCode == 0)
}

/// A process that reports in, then blocks until killed.
let sleeper = ProgramEntry { startup in
  try? Channel.write(startup, bytes: [1])
  let event = try? Event.create()
  _ = try? event?.wait(for: Signals.signaled)
  try? Channel.write(startup, bytes: [2])
}

@Test func killingAJobEndsItsProcessesEvenWhileTheyWait() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let child = try Job.create(parent: job)
  let a = try spawn(job, "sleeper-a", sleeper)
  let b = try spawn(child, "sleeper-b", sleeper)
  _ = try a.report.wait(for: Signals.readable, deadline: soon())
  _ = try b.report.wait(for: Signals.readable, deadline: soon())
  try kill(job)
  for s in [a.process.raw, b.process.raw] {
    try lending(s) { (p: borrowing Handle) throws(Status) in
      _ = try p.wait(for: Signals.terminated, deadline: soon())
      #expect(try Process.info(p).returnCode == -1024)
    }
  }
  #expect(try job.wait(for: Signals.terminated, deadline: 0) & Signals.terminated != 0)
  #expect(try child.wait(for: Signals.terminated, deadline: 0) & Signals.terminated != 0)
  for r in [a.report.raw, b.report.raw] {
    try lending(r) { (report: borrowing Handle) throws(Status) in
      _ = try Channel.read(report)  // the first message only
      #expect(statusOf { () throws(Status) in try Channel.read(report) } == .peerClosed)
    }
  }
  #expect(statusOf { () throws(Status) in try Process.create(job: job, name: "late") } == .badState)
}

@Test func aThreadCanBeKilledAlone() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let spawned = try spawn(job, "two", ProgramEntry { startup in
    try? Channel.write(startup, bytes: [1])
    // Lives until the host says so.
    _ = try? startup.wait(for: Signals.readable)
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  _ = try Channel.read(report)
  // A second thread in that process, blocked in a wait forever.
  let thread = try Thread.create(process: process)
  try Thread.start(thread) {
    let event = try? Event.create()
    _ = try? event?.wait(for: Signals.signaled)
  }
  _ = try thread.wait(for: Signals.threadRunning, deadline: soon())
  try kill(thread)
  _ = try thread.wait(for: Signals.terminated, deadline: soon())
  // The process goes on with its first thread.
  #expect(statusOf { () throws(Status) in try process.wait(for: Signals.terminated, deadline: 0) } == .timedOut)
  try Channel.write(report, bytes: [2])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
}

@Test func jobsNeedTheirRights() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let weak = try job.duplicate([.wait, .inspect])
  #expect(statusOf { () throws(Status) in try Process.create(job: weak, name: "x") } == .accessDenied)
  #expect(statusOf { () throws(Status) in try Job.create(parent: weak) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try kill(weak) } == .accessDenied)
  let event = try Event.create()
  #expect(statusOf { () throws(Status) in try Process.create(job: event, name: "x") } == .wrongType)
}

/// Runs `body(i)` on `count` threads and joins them.
enum DispatchlessParallel {
  final class Work: @unchecked Sendable {
    let body: @Sendable (Int) -> Void
    let index: Int
    init(_ body: @escaping @Sendable (Int) -> Void, _ index: Int) {
      self.body = body
      self.index = index
    }
  }

  static func run(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    var threads: [pthread_t] = []
    for i in 0..<count {
      var t = pthread_t()
      pthread_create(&t, nil, { arg in
        let w = Unmanaged<Work>.fromOpaque(arg!).takeRetainedValue()
        w.body(w.index)
        return nil
      }, Unmanaged.passRetained(Work(body, i)).toOpaque())
      threads.append(t)
    }
    for t in threads { pthread_join(t, nil) }
  }
}

// MARK: Locks, threads in this process, futexes (M3b)

@Test func processCurrentIsTheCallersProcess() throws {
  let me = try Process.current()
  let again = try Process.current()
  let a = try me.info(), b = try again.info()
  #expect(a.koid == b.koid && a.type == ObjectType.process)
}

@Test func spawnedThreadsRunAndJoin() throws {
  final class Box: @unchecked Sendable { var ran = 0 }
  let box = Box()
  let lock = Lock()
  var threads: [UInt32] = []
  for _ in 0..<4 {
    let t = try Thread.spawn {
      for _ in 0..<1000 { lock.withLock { box.ran += 1 } }
    }
    threads.append(t.release())
  }
  for raw in threads {
    let t = Handle(raw: raw)
    try Thread.join(t)
  }
  #expect(box.ran == 4000)
}

@Test func lockExcludesUnderContention() throws {
  final class Box: @unchecked Sendable { var inside = 0; var worst = 0; var total = 0 }
  let box = Box()
  let lock = Lock()
  var threads: [UInt32] = []
  for _ in 0..<8 {
    threads.append(try Thread.spawn {
      for _ in 0..<2000 {
        lock.lock()
        box.inside += 1
        box.worst = max(box.worst, box.inside)
        box.total += 1
        sched_yield()
        box.inside -= 1
        lock.unlock()
      }
    }.release())
  }
  for raw in threads { try Thread.join(Handle(raw: raw)) }
  #expect(box.total == 16000)
  #expect(box.worst == 1)
}

@Test func futexWaitChecksTheWordTimesOutAndWakes() throws {
  let word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
  defer { word.deallocate() }
  word.pointee = 0
  // A wait for a value the word doesn't hold refuses at once.
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 2) } == .badState)
  // One for the value it holds sleeps until its deadline...
  let start = Clock.monotonic()
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 0, deadline: start + 20_000_000) } == .timedOut)
  #expect(Clock.monotonic() - start >= 20_000_000)
  // ...or until a wake.
  let address = UInt(bitPattern: word)
  let waker = try Thread.spawn {
    usleep(20_000)
    Futex.wake(UnsafeMutablePointer<UInt32>(bitPattern: address)!, count: 1)
  }
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 0, deadline: Clock.monotonic() + 5 * second) } == .ok)
  try Thread.join(waker)
}
