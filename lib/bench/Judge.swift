// SPDX-License-Identifier: BSD-3-Clause

// Judging a run against its history (docs/performance.md §5): once a
// budget is met, a rise beyond its noise margin fails even while it is
// still under target, so the margin isn't spent silently.

/// The rule a measurement is judged by.
public struct Rule: Sendable {
  /// A rise above the baseline by more than this fraction fails...
  public var tolerance: Double
  /// ...but only if it is also larger than this many seconds (noise).
  public var floor: Double
  /// How many recent recorded runs form the baseline (their median).
  public var window: Int
  /// A hard target: above it fails whatever the history says.
  public var limit: Double? = nil
  /// What the values are: seconds, or a count of something.
  public var unit: Unit = .seconds

  public enum Unit: Sendable { case seconds, count }

  /// Incremental and no-change builds: a few seconds, steady to ±4%.
  public static let buildTime = Rule(tolerance: 0.10, floor: 0.25, window: 5)
  /// Clean builds: steady only to about ±6% on a shared machine (15.9 to
  /// 17.9 s measured for the same tree on 2026-10-09), so 10% fails on
  /// noise. 20% still catches what matters, such as swift-syntax no
  /// longer arriving prebuilt (more than double).
  public static let cleanBuild = Rule(tolerance: 0.20, floor: 2.0, window: 5)

  /// The tracer's own costs (docs/performance.md): an enabled zone under
  /// 20 ns, a disabled one about a load and a branch.
  public static let traceZoneEnabled = Rule(tolerance: 0.25, floor: 2e-9, window: 5, limit: 20e-9)
  public static let traceZoneDisabled = Rule(tolerance: 0.25, floor: 0.5e-9, window: 5, limit: 1e-9)

  // The reference programs (M1's exit; docs/performance.md §2). Counts
  // are exact, so any rise fails.
  /// sdk.md §3: at most 13 calls for window, frame, input and sound.
  public static let minimalCalls = Rule(tolerance: 0, floor: 0.5, window: 5, limit: 13, unit: .count)
  /// Nothing to do means no wakeups.
  public static let zero = Rule(tolerance: 0, floor: 0.5, window: 5, limit: 0, unit: .count)
  /// p99 frame error against present feedback, at most 1 ms. Below that,
  /// a rise of a quarter millisecond is noise on a shared desktop.
  public static let frameError = Rule(tolerance: 0.5, floor: 0.25e-3, window: 5, limit: 1e-3)
  /// Retains and allocations per frame: recorded per program; a rise
  /// fails. Each is counted exactly, but a frame's share moves with how
  /// events batch between waits (minimal: 45/26, then 40/23, on the same
  /// commit), so the rise must pass both 20% and 3 a frame.
  public static let perFrame = Rule(tolerance: 0.20, floor: 3, window: 5, unit: .count)

  /// The rule for a measurement, by name.
  public static func `for`(_ name: String) -> Rule {
    switch name {
    case "trace.zone.enabled": .traceZoneEnabled
    case "trace.zone.disabled": .traceZoneDisabled
    case "program.minimal.calls": .minimalCalls
    case "program.minimal.idle_wakeups", "program.synth.underruns": .zero
    case "program.gameloop.frame_error_p99": .frameError
    // Taisce (S0, ahead of M3's QEMU budgets): a live query's update after a
    // matching write, at most 1 ms; a cached 4 KiB read, M3's target 5 µs.
    case "program.taisce.live_p99": Rule(tolerance: 0.5, floor: 50e-6, window: 5, limit: 1e-3)
    case "program.taisce.read4k_p99": Rule(tolerance: 0.5, floor: 1e-6, window: 5, limit: 5e-6)
    // S1: the same read by a lock-free reader thread; how much slower a
    // read gets with four readers at once than alone (a ratio, at most
    // 1.5); fsync through the intent log and a group commit, on this
    // machine's disk (so its flush), at most 2 ms and 20 ms.
    case "program.taisce.reader_read4k_p99": Rule(tolerance: 0.5, floor: 1e-6, window: 5, limit: 5e-6)
    case "program.taisce.reader_slowdown_4": Rule(tolerance: 0.25, floor: 0.1, window: 5, limit: 1.5, unit: .count)
    case "program.taisce.fsync_p99": Rule(tolerance: 0.5, floor: 200e-6, window: 5, limit: 2e-3)
    case "program.taisce.commit_p99": Rule(tolerance: 0.5, floor: 2e-3, window: 5, limit: 20e-3)
    // A0: loading the ACPI corpus's largest machine (this one's 587 KiB of
    // AML, load-time code run) at most 5 ms; _STA on every device, 1 ms.
    case "program.acpi.load_p99": Rule(tolerance: 0.5, floor: 200e-6, window: 5, limit: 5e-3)
    case "program.acpi.sta_p99": Rule(tolerance: 0.5, floor: 50e-6, window: 5, limit: 1e-3)
    default:
      if name.hasPrefix("program.") { .perFrame } else if name.hasPrefix("build.clean.") { .cleanBuild } else { .buildTime }
    }
  }

  /// A value in this rule's unit.
  public func format(_ v: Double) -> String {
    switch unit {
    case .seconds: formatValue(v)
    case .count: v == v.rounded() ? String(Int(v)) : String(Double(Int(v * 10)) / 10)
    }
  }

  /// "+10%, 0.25 s", and the limit if there is one.
  public var summary: String {
    let rise = tolerance == 0 ? "any rise" : "+\(Int((tolerance * 100).rounded()))%, \(format(floor))"
    return rise + (limit.map { "; ≤ \(format($0))" } ?? "")
  }
}

public enum Verdict: Equatable {
  /// No history yet on this machine: recorded, not judged.
  case new
  case ok
  /// Slower than the baseline by more than the rule allows.
  case regressed
  /// Above the rule's hard limit.
  case overLimit
}

/// A measurement's judgement.
public struct Judgement: Equatable {
  public var name: String
  public var seconds: Double
  public var baseline: Double?
  public var verdict: Verdict
  public var rule: String
  public var unit: Rule.Unit = .seconds

  /// The change from the baseline, as a fraction.
  public var change: Double? { baseline.map { $0 > 0 ? (seconds - $0) / $0 : 0 } }
}

public func judge(_ name: String, seconds: Double, history: [Sample], rule: Rule) -> Judgement {
  let past = history.filter { $0.name == name }.suffix(rule.window).map(\.seconds)
  if let limit = rule.limit, seconds > limit {
    return Judgement(name: name, seconds: seconds, baseline: past.isEmpty ? nil : median(Array(past)),
                     verdict: .overLimit, rule: rule.summary, unit: rule.unit)
  }
  guard !past.isEmpty else {
    return Judgement(name: name, seconds: seconds, baseline: nil, verdict: .new, rule: rule.summary, unit: rule.unit)
  }
  let baseline = median(Array(past))
  let regressed = seconds > baseline * (1 + rule.tolerance) && seconds - baseline > rule.floor
  return Judgement(name: name, seconds: seconds, baseline: baseline, verdict: regressed ? .regressed : .ok,
                   rule: rule.summary, unit: rule.unit)
}

/// The budget report, in Markdown.
public func report(_ judgements: [Judgement], machine: String, commit: String, date: String) -> String {
  var out = """
    # Budget report

    Machine `\(machine)`, commit `\(commit)`, \(date). A measurement fails if it is slower
    than the median of the last 5 recorded runs on this machine by more than both parts of its
    rule (docs/performance.md). Times are medians of this run's repeats.

    | Budget | This run | Baseline | Change | Rule | Verdict |
    |---|---:|---:|---:|---|---|

    """
  for j in judgements {
    let change = j.change.map { (($0 >= 0 ? "+" : "") + String(Int(($0 * 100).rounded()))) + "%" } ?? "—"
    let verdict = switch j.verdict {
    case .new: "new"
    case .ok: "ok"
    case .regressed: "**OVER**"
    case .overLimit: "**OVER LIMIT**"
    }
    let show = { (v: Double) in Rule(tolerance: 0, floor: 0, window: 0, unit: j.unit).format(v) }
    out += "| `\(j.name)` | \(show(j.seconds)) | \(j.baseline.map(show) ?? "—") | \(change) | \(j.rule) | \(verdict) |\n"
  }
  return out
}
