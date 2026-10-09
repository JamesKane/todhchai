// SPDX-License-Identifier: BSD-3-Clause

// td bench: the build-time budgets (docs/performance.md §2, "Clean and
// incremental build time, per component"), judged against this machine's
// history in bench/history/.

import Bench
import FoundationEssentials
import Glibc

/// A component and a source file whose change rebuilds it.
let components: [(name: String, file: String)] = [
  ("IPCWire", "lib/ipc/wire/Encoder.swift"),
  ("IPCHost", "lib/ipc/host/HostKernel.swift"),
  ("IPCModel", "lib/ipc/model/Model.swift"),
  ("IPCMacros", "lib/ipc/macros/Generator.swift"),
  ("IPC", "lib/ipc/runtime/Codec.swift"),
  ("IDL", "lib/ipc/idl/CHeader.swift"),
  ("LibC", "lib/libc/string/Memory.swift"),
]

struct BenchOptions {
  var repeats = 5
  var cleanRepeats = 3
  var record = false
  var accept = false
}

/// The machine's name for its history file, and a description of it.
func machine() -> (id: String, description: String) {
  var name = [CChar](repeating: 0, count: 256)
  gethostname(&name, name.count)
  let host = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  let cpu = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8))?
    .split(separator: "\n").first { $0.hasPrefix("model name") }?
    .split(separator: ":", maxSplits: 1).last.map(trimmed) ?? "unknown CPU"
  let id = String(host.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
  return (id.isEmpty ? "unknown" : id, "\(host), \(cpu), \(sysconf(Int32(_SC_NPROCESSORS_ONLN))) CPUs")
}

func commitID() -> String {
  let head = capture(["git", "rev-parse", "--short", "HEAD"]) ?? "unknown"
  let dirty = !(capture(["git", "status", "--porcelain"]) ?? "").isEmpty
  return dirty ? "\(head)-dirty" : head
}

func today() -> String {
  var t = time(nil)
  var tm = tm()
  gmtime_r(&t, &tm)
  func two(_ n: Int32) -> String { n < 10 ? "0\(n)" : "\(n)" }
  return "\(tm.tm_year + 1900)-\(two(tm.tm_mon + 1))-\(two(tm.tm_mday))T\(two(tm.tm_hour)):\(two(tm.tm_min))Z"
}

func bench(_ options: BenchOptions) -> Bool {
  let out = "bench/out"
  removeTree("\(out)/logs")
  makeDirectory("\(out)/logs")
  let scratch = ".build/td-bench"  // its own, so it never waits on the developer's build
  let cmakeDir = "\(out)/embedded-incremental"
  var results: [(String, Double)] = []

  func measure(_ name: String, repeats: Int, before: () -> Void = {}, _ command: [[String]]) {
    let log = "\(out)/logs/\(name).log"
    var times: [Double] = []
    for _ in 0..<repeats {
      before()
      var total = 0.0
      for c in command {
        let r = run(c, log: log)
        guard r.ok else { fail("\(name): `\(c.joined(separator: " "))` failed; see \(log)") }
        total += r.seconds
      }
      times.append(total)
    }
    let m = median(times)
    say("  \(name): \(format(m)) s")
    results.append((name, m))
  }

  say("td bench: build times (\(options.repeats) repeats, clean builds \(options.cleanRepeats))")
  let cleanScratch = "\(out)/clean-scratch"
  measure("build.clean.hosted", repeats: options.cleanRepeats, before: { removeTree(cleanScratch) },
          [["swift", "build", "--scratch-path", cleanScratch]])
  removeTree(cleanScratch)
  let cleanCMake = "\(out)/clean-embedded"
  let configure = ["cmake", "-S", ".", "-B", cleanCMake, "-G", "Ninja", "-DCMAKE_TOOLCHAIN_FILE=cmake/embedded.cmake",
                   "-DCMAKE_BUILD_TYPE=RelWithDebInfo"]
  measure("build.clean.embedded", repeats: options.cleanRepeats, before: { removeTree(cleanCMake) },
          [configure, ["cmake", "--build", cleanCMake]])
  removeTree(cleanCMake)

  // Incremental builds start from a built tree.
  guard run(["swift", "build", "--scratch-path", scratch], log: "\(out)/logs/warm.log").ok else {
    fail("the warm-up build failed; see \(out)/logs/warm.log")
  }
  measure("build.noop.hosted", repeats: options.repeats, [["swift", "build", "--scratch-path", scratch]])
  for c in components {
    measure("build.incremental.\(c.name)", repeats: options.repeats, before: { touch(c.file) },
            [["swift", "build", "--scratch-path", scratch]])
  }
  removeTree(cmakeDir)
  _ = run(configure.map { $0 == cleanCMake ? cmakeDir : $0 }, log: "\(out)/logs/warm.log")
  _ = run(["cmake", "--build", cmakeDir], log: "\(out)/logs/warm.log")
  measure("build.incremental.embedded.IPCWire", repeats: options.repeats,
          before: { touch("lib/ipc/wire/Encoder.swift") }, [["cmake", "--build", cmakeDir]])

  // Judge against this machine's history.
  let (id, description) = machine()
  let historyPath = "bench/history/\(id).tsv"
  let history = parseHistory((try? String(contentsOfFile: historyPath, encoding: .utf8)) ?? "")
  let judgements = results.map { judge($0.0, seconds: $0.1, history: history, rule: .for($0.0)) }
  let commit = commitID()
  let date = today()
  let text = report(judgements, machine: description, commit: commit, date: date)
  try? text.write(toFile: "\(out)/report.md", atomically: true, encoding: .utf8)
  say("")
  say(text)

  let passed = !judgements.contains { $0.verdict == .regressed }
  if options.record && (passed || options.accept) {
    var file = (try? String(contentsOfFile: historyPath, encoding: .utf8))
      ?? "# Build-time history for \(description). Appended by td bench --record.\n"
    for j in judgements {
      file += Sample(date: date, commit: commit, name: j.name, seconds: j.seconds).line + "\n"
    }
    do { try file.write(toFile: historyPath, atomically: true, encoding: .utf8) } catch {
      fail("can't write \(historyPath)")
    }
    say("recorded in \(historyPath)")
  } else if options.record {
    say("not recorded: a budget regressed. Fix it, or re-decide with --accept (docs/performance.md §5).")
  }
  if !passed { say("logs of each measurement: \(out)/logs/") }
  return passed
}
