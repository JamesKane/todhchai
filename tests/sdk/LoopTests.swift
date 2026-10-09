// SPDX-License-Identifier: BSD-3-Clause

import Glibc
import Testing
import Todhchai

func timers(_ events: Events) -> [TimerID] {
  events.compactMap { if case .timer(let id, _) = $0.payload { id } else { nil } }
}

@Suite(.serialized) struct LoopTests {
  @Test func timersFireInDeadlineOrderAndNeverEarly() throws {
    var loop = try Loop()
    let start = Deadline.now
    let late = loop.timer(at: start + .milliseconds(30))
    let early = loop.timer(at: start + .milliseconds(10))
    var fired: [(TimerID, Deadline)] = []
    while fired.count < 2 {
      for e in loop.wait() {
        if case .timer(let id, _) = e.payload { fired.append((id, e.time)) }
      }
    }
    #expect(fired.map(\.0) == [early, late])
    #expect(fired[0].1 >= start + .milliseconds(10))
    #expect(fired[1].1 >= start + .milliseconds(30))
  }

  @Test func leewayCoalescesNearbyTimersIntoOneWakeup() throws {
    var loop = try Loop()
    let start = Deadline.now
    let a = loop.timer(at: start + .milliseconds(10), leeway: .milliseconds(20))
    let b = loop.timer(at: start + .milliseconds(25), leeway: .milliseconds(5))
    let before = loop.wakeups
    let events = loop.wait()
    #expect(Set(timers(events)) == [a, b])
    #expect(loop.wakeups - before == 1)
  }

  @Test func repeatingTimersDontDriftAndReportMissedRepeats() throws {
    var loop = try Loop()
    let start = Deadline.now
    _ = loop.timer(at: start + .milliseconds(5), repeating: .milliseconds(5))
    // Be late: by 28 ms the deadlines at 5 to 25 ms have passed. A busy
    // machine may wake us later still, which only means more missed.
    sleep(until: start + .milliseconds(28))
    var missed: UInt64 = 0
    for e in loop.wait() { if case .timer(_, let m) = e.payload { missed = m } }
    #expect(missed >= 4)
    // The next repeat stays on the original 5 ms grid, after the missed ones.
    let next = loop.wait()
    #expect(timers(next).count == 1)
    #expect(next[0].time >= start + .milliseconds(Int64(5 * (missed + 2))))
  }

  @Test func waitReturnsAtItsDeadlineWithNoEvents() throws {
    var loop = try Loop()
    let deadline = Deadline.now + .milliseconds(20)
    let events = loop.wait(until: deadline)
    #expect(events.isEmpty)
    #expect(Deadline.now >= deadline)
  }

  @Test func postsFromAnotherThreadArriveInOrder() throws {
    var loop = try Loop()
    let remote = loop.remote
    let sender = try Thread.spawn(intent: .interactive) {
      for i in 0..<100 { remote.post(Message(UInt64(i))) }
    }
    var received: [UInt64] = []
    while received.count < 100 {
      for e in loop.wait() { if case .message(let m) = e.payload { received.append(m.a) } }
    }
    sender.join()
    #expect(received == Array(0..<100))
  }

  @Test func wakesAreCoalesced() throws {
    var loop = try Loop()
    for _ in 0..<50 { loop.remote.wake() }
    let events = loop.wait()
    #expect(events.count == 1)
    if case .wake = events.first?.payload {} else { Issue.record("expected one wake") }
  }

  @Test func watchedFilesReportReadiness() throws {
    var loop = try Loop()
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    let id = try loop.watch(fd: fds[0], for: .readable)
    var byte: UInt8 = 7
    _ = write(fds[1], &byte, 1)
    let events = loop.wait()
    guard case .watch(let got, let readiness) = events.first?.payload else {
      Issue.record("expected a watch event")
      return
    }
    #expect(got == id && readiness.contains(.readable))
    try loop.unwatch(id)
  }

  /// The M1 budget "minimal: 0 idle wakeups": a loop with nothing due
  /// sleeps and doesn't wake until something happens.
  @Test func anIdleLoopDoesntWake() throws {
    var loop = try Loop()
    let remote = loop.remote
    let poker = try Thread.spawn(intent: .interactive) {
      sleep(until: .now + .milliseconds(300))
      remote.post(Message(1))
    }
    let before = loop.wakeups
    let events = loop.wait()
    poker.join()
    #expect(events.count == 1)
    #expect(loop.wakeups - before == 1)  // the post, and nothing in 300 ms before it
  }

  @Test func sigtermArrivesAsQuit() throws {
    var loop = try Loop()
    kill(getpid(), SIGTERM)  // to the process: the test runner's worker threads block signals
    var quit = false
    for e in loop.wait(until: .now + .milliseconds(500)) { if case .quit = e.payload { quit = true } }
    #expect(quit)
  }
}

@Test func intentsAreGrantedOrRefusedWithAReason() throws {
  let normal = try Thread.spawn(intent: .throughput) {}
  #expect(normal.admission == .notRealtime)
  normal.join()
  let rt = try Thread.spawn(intent: .realtime(period: .milliseconds(5), budget: .milliseconds(1), deadline: .milliseconds(5))) {}
  // Any of the three is a correct answer; which depends on the host's limits.
  #expect([.deadline, .fixedPriority, .refused(.noRealtimePrivilege)].contains(rt.admission))
  rt.join()
}

@Test func mutexesExcludeEachOther() throws {
  final class Counter: @unchecked Sendable { var n = 0; let m = Mutex() }
  let c = Counter()
  let a = try Thread.spawn(intent: .throughput) { for _ in 0..<10_000 { c.m.withLock { c.n += 1 } } }
  let b = try Thread.spawn(intent: .throughput) { for _ in 0..<10_000 { c.m.withLock { c.n += 1 } } }
  a.join()
  b.join()
  #expect(c.n == 20_000)
}
