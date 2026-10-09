// SPDX-License-Identifier: BSD-3-Clause

import Bench
import Testing

func samples(_ name: String, _ seconds: [Double]) -> [Sample] {
  seconds.map { Sample(date: "d", commit: "c", name: name, seconds: $0) }
}

@Test func firstRunIsNew() {
  #expect(judge("b", seconds: 9, history: [], rule: .buildTime).verdict == .new)
}

@Test func baselineIsTheMedianOfTheRecentWindow() {
  // Old slow runs fall out of the window of 5.
  let history = samples("b", [50, 50, 10, 10, 11, 9, 10])
  let j = judge("b", seconds: 10.5, history: history, rule: .buildTime)
  #expect(j.baseline == 10)
  #expect(j.verdict == .ok)
}

@Test func regressionNeedsBothTheFractionAndTheFloor() {
  let slow = samples("b", [10, 10, 10])
  #expect(judge("b", seconds: 11.2, history: slow, rule: .buildTime).verdict == .regressed)  // +12%, +1.2 s
  #expect(judge("b", seconds: 10.9, history: slow, rule: .buildTime).verdict == .ok)  // +9%
  let fast = samples("b", [1.0, 1.0, 1.0])
  #expect(judge("b", seconds: 1.2, history: fast, rule: .buildTime).verdict == .ok)  // +20%, but only 0.2 s
  #expect(judge("b", seconds: 1.3, history: fast, rule: .buildTime).verdict == .regressed)
}

@Test func cleanBuildsHaveAWiderRule() {
  #expect(Rule.for("build.clean.hosted").tolerance == 0.20)
  #expect(Rule.for("build.incremental.IPC").tolerance == 0.10)
  let history = samples("build.clean.hosted", [16.0])
  #expect(judge("build.clean.hosted", seconds: 17.9, history: history, rule: .for("build.clean.hosted")).verdict == .ok)
  #expect(judge("build.clean.hosted", seconds: 20, history: history, rule: .for("build.clean.hosted")).verdict == .regressed)
}

@Test func limitsFailWhateverTheHistory() {
  let rule = Rule.for("trace.zone.enabled")
  #expect(judge("trace.zone.enabled", seconds: 14e-9, history: [], rule: rule).verdict == .new)
  #expect(judge("trace.zone.enabled", seconds: 25e-9, history: [], rule: rule).verdict == .overLimit)
  #expect(formatValue(14.06e-9) == "14.1 ns" && formatValue(2.5e-3) == "2.5 ms" && formatValue(16.0044) == "16.004 s")
  let tiny = Sample(date: "d", commit: "c", name: "trace.zone.enabled", seconds: 1.4e-8)
  #expect(parseHistory(tiny.line).first?.seconds == 1.4e-8)
}

@Test func otherMeasurementsDontCount() {
  let history = samples("a", [1, 1, 1])
  #expect(judge("b", seconds: 5, history: history, rule: .buildTime).verdict == .new)
}

@Test func historyLinesRoundTrip() {
  let s = Sample(date: "2026-10-09T12:00Z", commit: "abc-dirty", name: "build.noop.hosted", seconds: 1.2345)
  #expect(s.line == "2026-10-09T12:00Z\tabc-dirty\tbuild.noop.hosted\t1.235")
  #expect(parseHistory("# comment\n" + s.line + "\nnot a sample\n").first?.seconds == 1.235)
  #expect(format(0.05) == "0.050")
  #expect(median([3, 1, 2]) == 2 && median([4, 1, 2, 3]) == 2.5)
}
