// SPDX-License-Identifier: BSD-3-Clause

// td ci: everything a change must pass, in one command. Each step's output
// is in bench/out/ci/<step>.log.

import Bench
import FoundationEssentials

/// Protocol files and the directory holding their API baselines.
let protocols: [(file: String, baselines: String)] = [
  ("tests/ipc/echo/Echo.swift", "tests/ipc/baselines"),
]

func ci(bench benchOptions: BenchOptions?) -> Bool {
  let logs = "bench/out/ci"
  removeTree(logs)
  makeDirectory(logs)
  var steps: [(String, [[String]])] = [
    ("hosted-build", [["swift", "build"]]),
    ("hosted-tests", [["swift", "test"]]),
    ("embedded", [["cmake", "--workflow", "--preset", "embedded"]]),
  ]
  for p in protocols {
    steps.append(("baseline \(p.file)", [["swift", "run", "idlc", "--baseline", p.baselines, p.file]]))
  }
  var passed = true
  for (name, commands) in steps {
    let log = "\(logs)/\(String(name.map { $0 == "/" || $0 == " " ? "_" : $0 })).log"
    var ok = true
    var seconds = 0.0
    for c in commands where ok {
      let r = run(c, log: log)
      ok = r.ok
      seconds += r.seconds
    }
    say("\(ok ? "ok  " : "FAIL") \(name) (\(format(seconds)) s)\(ok ? "" : ": see \(log)")")
    passed = passed && ok
  }
  if let benchOptions {
    passed = bench(benchOptions) && passed
  }
  say(passed ? "td ci: passed" : "td ci: FAILED")
  return passed
}
