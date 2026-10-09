// SPDX-License-Identifier: BSD-3-Clause

// The reference programs' budgets (docs/performance.md §2, M1), read out
// of their traces: the same records a person debugging a regression opens.

import TraceFormat
import TraceReader

/// A program's trace, with the questions its budgets ask.
public struct ProgramTrace {
  public let file: TraceFile

  public init(_ file: TraceFile) { self.file = file }

  /// When the first mark labeled `label` was written, in ticks.
  public func mark(_ label: String) -> UInt64? {
    file.records.first { $0.kind == TraceKind.mark.rawValue && TraceFile.label($0) == label }?.time
  }

  /// The values of counter `name` recorded between marks `from` and `to`
  /// (either may be nil: the trace's start or end).
  public func counters(_ name: String, from: String? = nil, to: String? = nil) -> [Int64] {
    let (lo, hi) = (from.flatMap(mark) ?? 0, to.flatMap(mark) ?? UInt64.max)
    return file.records.filter {
      $0.kind == TraceKind.counter.rawValue && file.name($0.a) == name && $0.time >= lo && $0.time <= hi
    }.map { Int64(bitPattern: $0.b) }
  }

  /// The last value of counter `name` at or before mark `at` (nil: the end).
  public func lastCounter(_ name: String, at: String? = nil) -> Int64? {
    counters(name, to: at).last
  }

  /// How many zones named `name` began at or after mark `from` and ended
  /// at or before mark `to`.
  public func zoneCount(_ name: String, from: String, to: String) -> Int? {
    guard let lo = mark(from), let hi = mark(to) else { return nil }
    return file.records.filter {
      $0.kind == TraceKind.zone.rawValue && file.name($0.b) == name && $0.time >= lo && $0.a <= hi
    }.count
  }
}

/// The value below which a fraction `p` of `values` lie (nearest rank).
public func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let s = values.sorted()
  let rank = Int((p * Double(s.count)).rounded(.up)) - 1
  return s[max(0, min(s.count - 1, rank))]
}

/// How many times the C program calls the functions named, counting call
/// sites, outside comments: the "≤ 13 calls" of sdk.md §3.
public func callSites(in source: String, of functions: [String]) -> Int {
  // Drop // and /* */ comments.
  var code = ""
  var i = source.startIndex
  while i < source.endIndex {
    let rest = source[i...]
    if rest.hasPrefix("//") {
      i = rest.firstIndex(of: "\n") ?? source.endIndex
    } else if rest.hasPrefix("/*") {
      var j = source.index(i, offsetBy: 2)
      while j < source.endIndex, !source[j...].hasPrefix("*/") { j = source.index(after: j) }
      i = j < source.endIndex ? source.index(j, offsetBy: 2) : source.endIndex
    } else {
      code.append(source[i])
      i = source.index(after: i)
    }
  }
  let names = Set(functions)
  var count = 0
  var word = ""
  var sawWord = ""
  for ch in code {
    if ch.isLetter || ch.isNumber || ch == "_" {
      word.append(ch)
      continue
    }
    if !word.isEmpty {
      sawWord = word
      word = ""
    }
    if ch == "(" {
      if names.contains(sawWord) { count += 1 }
      sawWord = ""
    } else if !ch.isWhitespace {
      sawWord = ""
    }
  }
  return count
}
