// SPDX-License-Identifier: BSD-3-Clause

// td: the Todhchai developer tool (sdk.md §13). M0 has:
//
//   td bench [--repeats N] [--clean-repeats N] [--record [--accept]]
//       Measures the build-time budgets and judges them against this
//       machine's history (bench/history/). --record appends a passing
//       run; --accept records a regressed one too, as a decision made in
//       the open (docs/performance.md §5).
//   td ci [--no-bench] [bench options]
//       Hosted build and tests, the Embedded build and tests, every
//       protocol's API baseline, then the bench.
//   td libc-symbols
//       Lists what the toolchain's Swift runtime imports from the C and
//       C++ runtimes, into lib/libc/symbols.tsv.
//
// Run from the repository root. Build td first and run its binary, so the
// builds td starts don't wait on SwiftPM's lock:
//   swift build --product td && .build/debug/td ci

import Bench
import FoundationEssentials
import Glibc

guard FileManager.default.fileExists(atPath: "Package.swift"),
  FileManager.default.fileExists(atPath: "CMakePresets.json")
else { fail("run td from the repository root") }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: td bench|ci [options]") }
args.removeFirst()

var options = BenchOptions()
var runBench = true
var i = 0
while i < args.count {
  func number() -> Int {
    i += 1
    guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("\(args[i - 1]) needs a number ≥ 1") }
    return n
  }
  switch args[i] {
  case "--repeats": options.repeats = number()
  case "--clean-repeats": options.cleanRepeats = number()
  case "--record": options.record = true
  case "--accept": options.accept = true
  case "--no-bench" where command == "ci": runBench = false
  default: fail("unknown option \(args[i])")
  }
  i += 1
}

switch command {
case "bench": exit(bench(options) ? 0 : 1)
case "ci": exit(ci(bench: runBench ? options : nil) ? 0 : 1)
case "libc-symbols": exit(libcSymbols() ? 0 : 1)
default: fail("unknown command \(command); td has bench, ci and libc-symbols")
}
