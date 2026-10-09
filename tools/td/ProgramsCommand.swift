// SPDX-License-Identifier: BSD-3-Clause

// td bench --programs: the reference programs' budgets (M1's exit;
// docs/performance.md §2), read from traces of release builds:
//
//   minimal   calls in minimal.c ≤ 13; 0 wakeups over 10 s with nothing to do
//   synth     0 underruns at 128 frames over 60 s (muted)
//   gameloop  p99 frame error ≤ 1 ms over 1,000+ frames
//   and Swift's retains and allocations per frame in each steady state.
//
// They open windows and play (silent) audio, so they need the desktop and
// are never part of td ci. Their traces stay in bench/out/programs/.

import ABIGen
import Bench
import FoundationEssentials
import Glibc
import TraceReader

func programBudgets(out: String) -> [(String, Double)] {
  guard getenv("WAYLAND_DISPLAY") != nil else {
    fail("td bench --programs needs a Wayland desktop: the programs open windows and play audio")
  }
  let scratch = ".build/td-bench-release"
  let traces = "\(out)/programs"
  removeTree(traces)
  makeDirectory(traces)
  for product in ["minimal", "synth", "gameloop"] {
    guard run(["swift", "build", "-c", "release", "--product", product, "--scratch-path", scratch],
              log: "\(out)/logs/build-\(product).log").ok
    else { fail("building \(product) failed; see \(out)/logs/build-\(product).log") }
  }

  /// Runs a program with tracing on, and returns its trace.
  func traced(_ name: String, _ env: [String]) -> ProgramTrace {
    let dir = "\(traces)/\(name)"
    makeDirectory(dir)
    let command = ["env", "TODHCHAI_TRACE=\(dir)", "TODHCHAI_TRACE_CATEGORIES=app,frame,audio,mark",
                   "TODHCHAI_SWIFT_COSTS=1"] + env + ["\(scratch)/release/\(name)"]
    say("  running \(name)…")
    guard run(command, log: "\(out)/logs/\(name).log").ok else { fail("\(name) failed; see \(out)/logs/\(name).log") }
    guard let file = traceFiles([dir]).first else { fail("\(name) left no trace in \(dir)") }
    return ProgramTrace(readTrace(file))
  }

  func perFrame(_ t: ProgramTrace, _ counter: String, from: String?, to: String?, skip: Int = 0) -> Double {
    let values = t.counters(counter, from: from, to: to).dropFirst(skip).map(Double.init)
    return values.isEmpty ? 0 : median(Array(values))
  }

  var results: [(String, Double)] = []
  func result(_ name: String, _ value: Double) {
    say("  \(name): \(Rule.for(name).format(value))")
    results.append((name, value))
  }

  // minimal: its calls, as the C program makes them; idle wakeups and
  // Swift costs from the Swift one.
  let functions = todhchaiABI(keys: []).decls.compactMap { if case .function(let f) = $0 { f.name } else { nil } }
  guard let c = try? String(contentsOfFile: "examples/minimal/minimal.c", encoding: .utf8) else {
    fail("can't read examples/minimal/minimal.c")
  }
  result("program.minimal.calls", Double(callSites(in: c, of: functions)))
  let minimal = traced("minimal", ["TODHCHAI_MINIMAL_FRAMES=600", "TODHCHAI_MINIMAL_IDLE=10"])
  guard let waits = minimal.zoneCount("loop.wait", from: "idle", to: "idle.end") else {
    fail("minimal's trace has no idle marks")
  }
  result("program.minimal.idle_wakeups", Double(max(0, waits - 1)))  // less the deadline that ends it
  result("program.minimal.retains_per_frame", perFrame(minimal, "swift.retains", from: nil, to: "idle", skip: 120))
  result("program.minimal.allocations_per_frame",
         perFrame(minimal, "swift.allocations", from: nil, to: "idle", skip: 120))

  // synth: underruns between its marks, at the period it got.
  let synth = traced("synth", ["TODHCHAI_SYNTH_SECONDS=60", "TODHCHAI_SYNTH_GAIN=0"])
  let periods = Set(synth.counters("audio.period"))
  if periods != [128] {
    say("  synth: the audio graph ran at \(periods.sorted()) frames a period; the budget is at 128")
  }
  let underruns = (synth.lastCounter("audio.underruns", at: "steady.end") ?? 0)
    - (synth.lastCounter("audio.underruns", at: "steady") ?? 0)
  result("program.synth.underruns", Double(underruns))

  // gameloop: frame error, either way, and its Swift costs.
  let game = traced("gameloop", ["TODHCHAI_GAMELOOP_FRAMES=1200"])
  let errors = game.counters("frame.error", from: "steady", to: "steady.end").map { abs(Double($0)) * 1e-9 }
  if errors.count < 1000 { say("  gameloop: only \(errors.count) frames had measured timing (want 1,000)") }
  result("program.gameloop.frame_error_p99", percentile(errors, 0.99))
  result("program.gameloop.retains_per_frame", perFrame(game, "swift.retains", from: "steady", to: "steady.end"))
  result("program.gameloop.allocations_per_frame",
         perFrame(game, "swift.allocations", from: "steady", to: "steady.end"))
  return results
}
