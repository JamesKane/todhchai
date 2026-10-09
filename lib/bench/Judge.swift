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

  /// The rule for a measurement, by name.
  public static func `for`(_ name: String) -> Rule {
    switch name {
    case "trace.zone.enabled": .traceZoneEnabled
    case "trace.zone.disabled": .traceZoneDisabled
    default: name.hasPrefix("build.clean.") ? .cleanBuild : .buildTime
    }
  }

  /// "+10%, 0.25 s", and the limit if there is one.
  public var summary: String {
    "+\(Int((tolerance * 100).rounded()))%, \(formatValue(floor))" + (limit.map { "; ≤ \(formatValue($0))" } ?? "")
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

  /// The change from the baseline, as a fraction.
  public var change: Double? { baseline.map { $0 > 0 ? (seconds - $0) / $0 : 0 } }
}

public func judge(_ name: String, seconds: Double, history: [Sample], rule: Rule) -> Judgement {
  let past = history.filter { $0.name == name }.suffix(rule.window).map(\.seconds)
  if let limit = rule.limit, seconds > limit {
    return Judgement(name: name, seconds: seconds, baseline: past.isEmpty ? nil : median(Array(past)),
                     verdict: .overLimit, rule: rule.summary)
  }
  guard !past.isEmpty else {
    return Judgement(name: name, seconds: seconds, baseline: nil, verdict: .new, rule: rule.summary)
  }
  let baseline = median(Array(past))
  let regressed = seconds > baseline * (1 + rule.tolerance) && seconds - baseline > rule.floor
  return Judgement(
    name: name, seconds: seconds, baseline: baseline, verdict: regressed ? .regressed : .ok, rule: rule.summary)
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
    out += "| `\(j.name)` | \(formatValue(j.seconds)) | \(j.baseline.map(formatValue) ?? "—") | \(change) | \(j.rule) | \(verdict) |\n"
  }
  return out
}
