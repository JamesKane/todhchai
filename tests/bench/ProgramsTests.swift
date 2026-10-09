// SPDX-License-Identifier: BSD-3-Clause

// The reference programs' budgets, read from synthetic traces.

import Bench
import TraceFormat
import TraceReader
import Testing

/// A trace at 1 GHz (ticks are ns) of the records given.
func trace(_ records: [TraceRecord]) -> ProgramTrace {
  ProgramTrace(TraceFile(counterHz: 1_000_000_000, records: records,
                         names: [1: "loop.wait", 2: "frame.error", 3: "audio.underruns"]))
}

func mark(_ t: UInt64, _ label: String) -> TraceRecord {
  var a: UInt64 = 0, b: UInt64 = 0  // 16 bytes of label, as Trace.mark packs them
  for (i, byte) in label.utf8.prefix(16).enumerated() {
    if i < 8 { a |= UInt64(byte) << (8 * i) } else { b |= UInt64(byte) << (8 * (i - 8)) }
  }
  return TraceRecord(time: t, kind: TraceKind.mark.rawValue, a: a, b: b)
}
func zone(_ start: UInt64, _ end: UInt64) -> TraceRecord {
  TraceRecord(time: start, kind: TraceKind.zone.rawValue, a: end, b: 1)
}
func counter(_ t: UInt64, _ name: UInt64, _ v: Int64) -> TraceRecord {
  TraceRecord(time: t, kind: TraceKind.counter.rawValue, a: name, b: UInt64(bitPattern: v))
}

@Test func idleWakeupsAreZonesInsideTheMarks() {
  let t = trace([zone(0, 50), mark(100, "idle"), zone(100, 10_100), mark(10_200, "idle.end"), zone(10_300, 10_400)])
  #expect(t.zoneCount("loop.wait", from: "idle", to: "idle.end") == 1)  // the deadline's own
  #expect(t.zoneCount("loop.wait", from: "missing", to: "idle.end") == nil)
}

@Test func countersAreTakenBetweenMarks() {
  let t = trace([counter(10, 2, 5_000_000), mark(100, "steady"), counter(110, 2, -20), counter(120, 2, 900),
                 mark(200, "steady.end"), counter(210, 2, 7)])
  #expect(t.counters("frame.error", from: "steady", to: "steady.end") == [-20, 900])
  #expect(t.counters("frame.error") == [5_000_000, -20, 900, 7])
  #expect(t.lastCounter("frame.error", at: "steady") == 5_000_000)
}

@Test func percentilesAreNearestRank() {
  let values = (1...100).map(Double.init)
  #expect(percentile(values, 0.99) == 99)
  #expect(percentile(values, 0.5) == 50)
  #expect(percentile([3], 0.99) == 3)
  #expect(percentile([], 0.99) == 0)
}

@Test func callSitesSkipCommentsAndDeclarations() {
  let source = """
    // td_loop_create() in a comment
    int main(void) {
      td_loop *loop = td_loop_create();  /* td_present( */
      td_frame_request(loop, w);
      if (x) td_frame_request (loop, w);
      return td_loop_wait_extra(1);
    }
    """
  #expect(callSites(in: source, of: ["td_loop_create", "td_frame_request", "td_present", "td_loop_wait"]) == 3)
}

@Test func countsAreJudgedExactly() {
  let rule = Rule.for("program.minimal.idle_wakeups")
  #expect(judge("program.minimal.idle_wakeups", seconds: 0, history: [], rule: rule).verdict == .new)
  #expect(judge("program.minimal.idle_wakeups", seconds: 1, history: [], rule: rule).verdict == .overLimit)
  let perFrame = Rule.for("program.gameloop.allocations_per_frame")
  let past = [Sample(date: "d", commit: "c", name: "program.gameloop.allocations_per_frame", seconds: 26)]
  #expect(judge("program.gameloop.allocations_per_frame", seconds: 26, history: past, rule: perFrame).verdict == .ok)
  #expect(judge("program.gameloop.allocations_per_frame", seconds: 28, history: past, rule: perFrame).verdict == .ok)
  #expect(judge("program.gameloop.allocations_per_frame", seconds: 32, history: past, rule: perFrame).verdict == .regressed)
  #expect(judge("program.gameloop.allocations_per_frame", seconds: 20, history: past, rule: perFrame).verdict == .ok)
  #expect(Rule.for("program.minimal.calls").format(11) == "11")
}
