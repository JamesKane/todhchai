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

  public static let buildTime = Rule(tolerance: 0.10, floor: 0.25, window: 5)
}

public enum Verdict: Equatable {
  /// No history yet on this machine: recorded, not judged.
  case new
  case ok
  /// Slower than the baseline by more than the rule allows.
  case regressed
}

/// A measurement's judgement.
public struct Judgement: Equatable {
  public var name: String
  public var seconds: Double
  public var baseline: Double?
  public var verdict: Verdict

  /// The change from the baseline, as a fraction.
  public var change: Double? { baseline.map { $0 > 0 ? (seconds - $0) / $0 : 0 } }
}

public func judge(_ name: String, seconds: Double, history: [Sample], rule: Rule) -> Judgement {
  let past = history.filter { $0.name == name }.suffix(rule.window).map(\.seconds)
  guard !past.isEmpty else { return Judgement(name: name, seconds: seconds, baseline: nil, verdict: .new) }
  let baseline = median(Array(past))
  let regressed = seconds > baseline * (1 + rule.tolerance) && seconds - baseline > rule.floor
  return Judgement(name: name, seconds: seconds, baseline: baseline, verdict: regressed ? .regressed : .ok)
}

/// The budget report, in Markdown.
public func report(_ judgements: [Judgement], machine: String, commit: String, date: String) -> String {
  var out = """
    # Budget report

    Machine `\(machine)`, commit `\(commit)`, \(date). Rule: a measurement fails if it is more
    than 10% and more than 0.25 s slower than the median of the last 5 recorded runs on this
    machine (docs/performance.md). Times are medians of this run's repeats, in seconds.

    | Budget | This run | Baseline | Change | Verdict |
    |---|---:|---:|---:|---|

    """
  for j in judgements {
    let change = j.change.map { (($0 >= 0 ? "+" : "") + String(Int(($0 * 100).rounded()))) + "%" } ?? "—"
    let verdict = switch j.verdict {
    case .new: "new"
    case .ok: "ok"
    case .regressed: "**OVER**"
    }
    out += "| `\(j.name)` | \(format(j.seconds)) | \(j.baseline.map(format) ?? "—") | \(change) | \(verdict) |\n"
  }
  return out
}
