// SPDX-License-Identifier: BSD-3-Clause

// bin/acpi-bench: A0's budgets measured on croi (M3h), as tools/acpi-bench
// measures them hosted: loading a machine's DSDT and SSDTs with load-time
// code run, and _STA on every device, 50 times each, with no regions
// handled (a corpus machine's memory isn't here). The tables are bootfs's
// data/ files, from the out-of-tree corpus:
//
//     td boot --test --next bin/acpi-bench --data .cache/acpi/brimstone
//
// With no tables in bootfs it measures nothing and says so.

import LibSys
import Sys
import TDACPI

/// No regions; _OSI as Windows; no time passes in Sleep or Stall.
final class BenchHost: ACPIHost {
  func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  func sleep(milliseconds: UInt64) {}
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) {}
  func timer() -> UInt64 { 0 }
  func debug(_ text: [UInt8]) {}
  func fatal(type: UInt8, code: UInt32, argument: UInt64) {}
}

@main struct ACPIBench {
  static let runs = 50

  /// Microseconds, with one decimal.
  static func us(_ ns: Int64) -> String { "\(ns / 1000).\((ns % 1000) / 100)" }

  static func main() {
    let boot = Boot()
    var tables: [Table] = []
    for d in boot.data where d.name == "DSDT" || d.name.utf8.starts(with: "SSDT".utf8) {
      guard !d.name.utf8.contains(UInt8(ascii: ".")),
        let bytes = try? VMO.read(boot.bootfs, offset: d.offset, count: d.length), let t = try? Table(bytes)
      else { continue }
      tables.append(t)
    }
    tables.sort { ($0.signature == .dsdt ? 0 : 1) < ($1.signature == .dsdt ? 0 : 1) }
    guard tables.first?.signature == .dsdt else {
      print("acpi-bench: no DSDT in bootfs's data/ (td boot --data .cache/acpi/NAME): nothing measured")
      return
    }
    let bytes = tables.reduce(0) { $0 + $1.length }
    let host = BenchHost()
    var ns = Namespace()
    var loads: [Int64] = []
    for _ in 0..<runs {
      ns = Namespace()
      let t0 = Clock.monotonic()
      for t in tables { try? ns.load(t, host: host) }
      loads.append(Clock.monotonic() - t0)
    }
    let devices = ns.deviceNodes()
    var present = 0
    var stas: [Int64] = []
    for _ in 0..<runs {
      present = 0
      let t0 = Clock.monotonic()
      for d in devices where (try? ns.status(d, host: host))?.present == true { present += 1 }
      stas.append(Clock.monotonic() - t0)
    }
    loads.sort()
    stas.sort()
    let p99 = runs * 99 / 100
    print("acpi-bench: \(tables.count) tables (\(bytes / 1024) KiB), \(ns.nodes.count) nodes, \(devices.count) devices (\(present) present)")
    print("acpi-bench: acpi.load median \(us(loads[runs / 2])) us, p99 \(us(loads[p99])) us (budget 5000 us)")
    print("acpi-bench: acpi.sta median \(us(stas[runs / 2])) us, p99 \(us(stas[p99])) us (budget 1000 us)")
  }
}
