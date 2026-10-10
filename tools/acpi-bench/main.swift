// SPDX-License-Identifier: BSD-3-Clause

// acpi-bench: A0's budgets (docs/milestones/A0.md, docs/performance.md),
// from trace zones, on the corpus's largest machine (.cache/acpi; td acpi):
//
//   acpi.load   loading its DSDT and SSDTs, load-time code run
//   acpi.sta    evaluating _STA on every device
//
// With no corpus it measures nothing and says so.
//
//   swift build -c release --product acpi-bench
//   .build/debug/td trace record -o DIR -- .build/release/acpi-bench

import Glibc
import TDACPI
import Trace

enum Names {
  static let load = TraceName("acpi.load")
  static let sta = TraceName("acpi.sta")
}

func readFile(_ path: String) -> [UInt8]? {
  guard let f = fopen(path, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65_536)
  while true {
    let n = chunk.withUnsafeMutableBytes { fread($0.baseAddress, 1, 65_536, f) }
    if n == 0 { break }
    out += chunk[..<n]
  }
  return out
}

func list(_ dir: String) -> [String] {
  guard let d = opendir(dir) else { return [] }
  defer { closedir(d) }
  var out: [String] = []
  while let e = readdir(d) {
    let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    if !name.hasPrefix(".") { out.append(name) }
  }
  return out.sorted()
}

/// No regions read (a real machine's memory isn't here); _OSI as Windows.
final class BenchHost: ACPIHost {
  func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  func sleep(milliseconds: UInt64) {}
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) {}
  func timer() -> UInt64 { 0 }
  func debug(_ text: [UInt8]) {}
  func fatal(type: UInt8, code: UInt32, argument: UInt64) {}
}

_ = Trace.startFromEnvironment()
let corpus = ".cache/acpi"
// The machine with the most AML, and its DSDT and SSDTs.
var best: (machine: String, tables: [Table], bytes: Int)? = nil
for machine in list(corpus) {
  let files = list("\(corpus)/\(machine)").filter {
    ($0 == "DSDT" || $0.hasPrefix("SSDT") || $0.hasPrefix("dynamic-SSDT")) && !$0.contains(".")
  }
  let tables = files.compactMap { readFile("\(corpus)/\(machine)/\($0)").flatMap { try? Table($0) } }
    .sorted { ($0.signature == .dsdt ? 0 : 1) < ($1.signature == .dsdt ? 0 : 1) }
  let bytes = tables.reduce(0) { $0 + $1.length }
  if bytes > (best?.bytes ?? 0) { best = (machine, tables, bytes) }
}
guard let (machine, tables, bytes) = best else {
  print("acpi-bench: no corpus in \(corpus) (td acpi import, td acpi fetch-qemu): nothing measured")
  exit(0)
}
let host = BenchHost()
var ns = Namespace()
for _ in 0..<50 {
  ns = Namespace()
  let start = Trace.now()
  for t in tables { try? ns.load(t, host: host) }
  Trace.zone(Names.load, .app, since: start)
}
let devices = ns.deviceNodes()
var present = 0
for _ in 0..<50 {
  let start = Trace.now()
  present = 0
  for d in devices where (try? ns.status(d, host: host))?.present == true { present += 1 }
  Trace.zone(Names.sta, .app, since: start)
}
print("acpi-bench: \(machine), \(tables.count) tables (\(bytes / 1024) KiB), \(devices.count) devices (\(present) present)")
