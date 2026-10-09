// SPDX-License-Identifier: BSD-3-Clause

// The tracer's own budgets (docs/performance.md §2, "The tracer's own
// budgets"), measured in a release build by td bench. Prints, in
// nanoseconds per trace point:
//
//   zone.enabled <ns>     a zone, begin and end, recorded
//   zone.disabled <ns>    a zone whose category is off
//   empty <ns>            the loop alone, subtracted from both

import Glibc
import Trace

let iterations = 2_000_000
let name = TraceName("cost")

func ns() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) * 1e9 + Double(ts.tv_nsec)
}

/// The best of 5 runs of `body` over `iterations`, per iteration.
func measure(_ body: () -> Void) -> Double {
  var best = Double.infinity
  for _ in 0..<5 {
    let t = ns()
    for _ in 0..<iterations { body() }
    best = min(best, (ns() - t) / Double(iterations))
  }
  return best
}

nonisolated(unsafe) var sink = 0
let path = "/tmp/todhchai-trace-cost-\(getpid()).trace"
defer { unlink(path) }
// Under `td trace record` the recording is the environment's; otherwise a
// scratch file of our own.
guard Trace.startFromEnvironment()
  || Trace.start(path: path, categories: [.app], circular: true, recordsPerRing: 1 << 16)
else {
  fatalError("can't start a trace at \(path)")
}
let empty = measure { sink &+= 1 }
let enabled = measure { Trace.zone(name, .app) { sink &+= 1 } }
let disabled = measure { Trace.zone(name, .audio) { sink &+= 1 } }
print("zone.enabled \(max(0, enabled - empty))")
print("zone.disabled \(max(0, disabled - empty))")
print("empty \(empty)")
