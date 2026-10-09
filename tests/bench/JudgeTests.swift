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
