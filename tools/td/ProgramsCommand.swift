// SPDX-License-Identifier: BSD-3-Clause

// td bench --programs: the reference programs' budgets (M1's exit;
// docs/performance.md §2), read from traces of release builds:
//
//   minimal   calls in minimal.c ≤ 13; 0 wakeups over 10 s with nothing to do
//   synth     0 underruns at 128 frames over 60 s (muted)
//   gameloop  p99 frame error ≤ 1 ms over 1,000+ frames
//   taisce    a cached 4 KiB read, and a live query's update after a
//             matching write (S0, ahead of M3's QEMU budgets); the read by
//             a lock-free reader, four readers' slowdown, fsync and a
//             group commit on the host's disk (S1)
//   acpi      loading the ACPI corpus's largest machine, and _STA on every
//             device (A0); only with a corpus (td acpi)
//   n0        a channel call's round trip (its IPC flow, which must join
//             all four steps), a Node walk and read, a 4 KiB block read
//             through the ring, a live query's update through the fs
//             service, and launch to ready (N0's exit)
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
  for product in ["minimal", "synth", "gameloop", "taisce-bench", "acpi-bench", "n0-bench"] {
    guard run(["swift", "build", "-c", "release", "--product", product, "--scratch-path", scratch],
              log: "\(out)/logs/build-\(product).log").ok
    else { fail("building \(product) failed; see \(out)/logs/build-\(product).log") }
  }

  /// Runs a program with tracing on, and returns its trace.
  func traced(_ name: String, _ env: [String], categories: String = "app,frame,audio,mark") -> ProgramTrace {
    let dir = "\(traces)/\(name)"
    makeDirectory(dir)
    let command = ["env", "TODHCHAI_TRACE=\(dir)", "TODHCHAI_TRACE_CATEGORIES=\(categories)",
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
  // Taisce (S0): its budgets from zones, on an in-memory volume.
  let taisce = traced("taisce-bench", [])
  let zones = taisce.file.zones()
  result("program.taisce.read4k_p99", percentile(zones["fs.read4k"] ?? [], 0.99))
  result("program.taisce.live_p99", percentile(zones["fs.live"] ?? [], 0.99))
  result("program.taisce.reader_read4k_p99", percentile(zones["fs.read4k.reader"] ?? [], 0.99))
  if let one = taisce.lastCounter("fs.readers.ns.1"), let four = taisce.lastCounter("fs.readers.ns.4"), one > 0 {
    result("program.taisce.reader_slowdown_4", Double(four) / Double(one))
  }
  result("program.taisce.fsync_p99", percentile(zones["fs.fsync"] ?? [], 0.99))
  result("program.taisce.commit_p99", percentile(zones["fs.commit"] ?? [], 0.99))
  // ACPI (A0): loading the corpus's largest machine and _STA on its every
  // device; nothing without a corpus (td acpi), which stays out of the tree.
  let acpi = traced("acpi-bench", []).file.zones()
  if let load = acpi["acpi.load"], let sta = acpi["acpi.sta"] {
    result("program.acpi.load_p99", percentile(load, 0.99))
    result("program.acpi.sta_p99", percentile(sta, 0.99))
  } else {
    say("  acpi-bench: no corpus (td acpi import, td acpi fetch-qemu); ACPI budgets not measured")
  }
  // N0 (M3's services, hosted): from zones, and from the IPC flows the
  // calls record, which must each join the call's write, the server's
  // read, the reply's write and the caller's read.
  let n0 = traced("n0-bench", [], categories: "app,ipc,mark").file
  let n0Zones = n0.zones()
  let calls = n0.flows()["Node.stat"] ?? []
  result("program.n0.call_p99", percentile(calls.map(\.seconds), 0.99))
  result("program.n0.call_unjoined", Double(calls.filter { $0.steps != 4 }.count + (calls.isEmpty ? 1 : 0)))
  result("program.n0.walk_read_p99", percentile(n0Zones["node.walk_read"] ?? [], 0.99))
  result("program.n0.block_read4k_p99", percentile(n0Zones["block.read4k"] ?? [], 0.99))
  result("program.n0.live_p99", percentile(n0Zones["fs.live"] ?? [], 0.99))
  result("program.n0.launch_p99", percentile(n0Zones["launch.ready"] ?? [], 0.99))
  return results
}
