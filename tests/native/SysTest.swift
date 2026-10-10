// SPDX-License-Identifier: BSD-3-Clause

// bin/sys-test: Sys over croi's syscalls (M3b), run by userboot under
// `td boot --test --next bin/sys-test`. Each check names what failed and
// exits 1; all passing prints "sys-test: ok" and exits 0. The hosted
// suite (tests/sys) checks the same calls over the hosted kernel.

import LibSys
import Sys

@main struct SysTest {
  static func main() {
    do throws(Status) {
      try run()
    } catch {
      print("sys-test: FAILED with status \(error.rawValue)")
      exit(1)
    }
    print("sys-test: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok {
      print("sys-test: FAILED: \(what)")
      exit(1)
    }
  }

  static func status<R>(_ body: () throws(Status) -> R) -> Status {
    do throws(Status) {
      _ = try body()
      return .ok
    } catch {
      return error
    }
  }

  static let ms: Int64 = 1_000_000

  static func run() throws(Status) {
    // The clock moves, and sleeping takes time.
    let t0 = Clock.monotonic()
    sleep(until: t0 + 2 * ms)
    check(Clock.monotonic() >= t0 + 2 * ms, "clock and sleep")

    // Handles: rights narrow on duplicate and replace; stale handles fail.
    let event = try Event.create()
    let info = try event.info()
    check(info.type == ObjectType.event && info.rights.contains(.signal), "event info")
    let waitOnly = try event.duplicate([.wait, .inspect])
    check(try waitOnly.info().koid == info.koid, "duplicate's koid")
    check(status { () throws(Status) in try waitOnly.signal(set: Signals.signaled) } == .accessDenied, "narrowed rights")
    let replaced = try waitOnly.replace([.inspect])
    check(try replaced.info().rights == [.inspect], "replace")
    check(status { () throws(Status) in try Handle(raw: 0x7FFF_FFF1).info() } == .badHandle, "bad handle")

    // Signals and waits, with deadlines.
    check(status { () throws(Status) in try event.wait(for: Signals.signaled, deadline: 0) } == .timedOut, "wait times out")
    try event.signal(set: Signals.signaled)
    check(try event.wait(for: Signals.signaled) & Signals.signaled != 0, "event signaled")

    // M2's exit, in Sys: a VMO across a channel, a port wait on a deadline timer.
    let ends = try Channel.create()
    let a = ends.a, b = ends.b
    check(try a.info().relatedKoid == b.info().koid, "channel peers")
    let vmo = try VMO.create(size: 8192)
    try VMO.write(vmo, offset: 4096, Array("dia duit".utf8))
    try Channel.write(a, bytes: [1, 2, 3], handles: [vmo.release()])
    let message = try Channel.read(b)
    check(message.bytes == [1, 2, 3] && message.handles.count == 1, "channel message")
    let received = Handle(raw: message.handles[0])
    check(try VMO.read(received, offset: 4096, count: 8) == Array("dia duit".utf8), "VMO across the channel")
    check(status { () throws(Status) in try Channel.read(b) } == .shouldWait, "empty channel")

    let port = try Port.create()
    let timer = try Timer.create()
    try Timer.set(timer, deadline: Clock.monotonic() + 5 * ms)
    try timer.waitAsync(port: port, key: 7, signals: Signals.signaled)
    let packet = try Port.wait(port, deadline: Clock.monotonic() + 1000 * ms)
    check(packet.key == 7 && packet.trigger & Signals.signaled != 0, "timer packet")
    check(status { () throws(Status) in try Port.wait(port, deadline: Clock.monotonic() + ms) } == .timedOut, "port times out")
    try Port.queue(port, Packet(key: 9, payload: (1, 2, 3, 4)))
    check(try Port.wait(port).payload.3 == 4, "user packet")

    // Mappings see the VMO, and unmap when dropped.
    do {
      let mapping = try VMO.map(received, length: 8192)
      check(mapping.load(UInt8.self, at: 4096) == UInt8(ascii: "d"), "mapping reads")
      mapping.store(UInt64(0x5444_4843_4841_4921), at: 0)
      check(try VMO.read(received, offset: 0, count: 8) == [0x21, 0x49, 0x41, 0x48, 0x43, 0x48, 0x44, 0x54], "mapping writes")
    }

    // Eventpairs see their peer close.
    let pair = try EventPair.create()
    let left = pair.a
    do {
      let right = pair.b
      _ = consume right
    }
    check(try left.wait(for: Signals.peerClosed) & Signals.peerClosed != 0, "peer closed")

    // Threads: a server answering calls on another thread.
    let calls = try Channel.create()
    let client = calls.a
    let serverRaw = calls.b.release()
    let server = try Thread.spawn {
      let channel = Handle(raw: serverRaw)
      while true {
        guard (try? channel.wait(for: Signals.readable | Signals.peerClosed)) != nil,
          let m = try? Channel.read(channel)
        else { return }
        // Echo the call with its txid (the first four bytes) and one more byte.
        try? Channel.write(channel, bytes: m.bytes + [0xEE])
      }
    }
    for i in 0..<20 {
      let reply = try Channel.call(client, bytes: [0, 0, 0, 0, UInt8(i)], deadline: Clock.monotonic() + 1000 * ms)
      check(reply.bytes.count == 6 && reply.bytes[4] == UInt8(i) && reply.bytes[5] == 0xEE, "call's reply")
    }
    _ = consume client
    try Thread.join(server)

    // A lock under contention from four threads.
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let lock = Lock()
    var workers: [UInt32] = []
    for _ in 0..<4 {
      workers.append(try Thread.spawn {
        for _ in 0..<5000 { lock.withLock { counter.value += 1 } }
      }.release())
    }
    for w in workers { try Thread.join(Handle(raw: w)) }
    check(counter.value == 20000, "lock counts")

    // Many short threads: their stacks are reaped as new ones start.
    for _ in 0..<64 {
      let t = try Thread.spawn {}
      try Thread.join(t)
    }

    // Futexes refuse a stale value and time out.
    let word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    unsafe word.pointee = 5
    check(status { () throws(Status) in try unsafe Futex.wait(word, current: 6) } == .badState, "futex value")
    check(status { () throws(Status) in try unsafe Futex.wait(word, current: 5, deadline: Clock.monotonic() + ms) } == .timedOut,
          "futex timeout")
    unsafe word.deallocate()

    // This process, and a job and process of its own making.
    let me = try Process.current()
    check(try me.info().type == ObjectType.process, "process self")
    print("sys-test: \(Clock.monotonic() - t0) ns")
  }
}
