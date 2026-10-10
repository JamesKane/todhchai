// SPDX-License-Identifier: BSD-3-Clause

// bin/devices-test: devmgr's test on croi (M3g), a client the launcher
// starts beside devmgr (tests/native/devices). Run by
//
//     td boot --test --manifests tests/native/devices --cmdline launcher.until=devices-test -- -device edu
//
// It reads devmgr's status through /svc: q35's host bridge and the ESP's
// virtio-blk are found and left unbound, the edu device is bound to bin/edu
// and running; then reads the edu driver host's own tree through devmgr's,
// where the driver reports what it did with the device it was given.

import Launch
import LibSys
import Node
import Sys

@main struct DevicesTest {
  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok {
      print("devices-test: FAILED: \(what)")
      exit(1)
    }
  }

  static func read(_ ns: Namespace, _ path: String) -> String? {
    guard var c = try? ns.open(path) else { return nil }
    return try? c.readText()
  }

  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    let ns: Namespace
    do { ns = try Startup(Handle(raw: raw)).namespace } catch { exit(2) }

    guard let status = read(ns, "/svc/devmgr/status") else {
      print("devices-test: FAILED: reading /svc/devmgr/status")
      exit(1)
    }
    for line in status.split(separator: "\n") { print("devices-test: \(line)") }
    // name ids class service state
    let lines = status.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    check(lines.allSatisfy { $0.count == 5 }, "status lines")
    let bridge = lines.first { $0[1] == "8086:29c0" }
    check(bridge?[3] == "-" && bridge?[4] == "unbound", "the host bridge, unbound")
    check(lines.contains { $0[1].utf8.starts(with: "1af4:".utf8) && $0[2].utf8.starts(with: "01.".utf8) },
          "the ESP's virtio-blk")
    guard let edu = lines.first(where: { $0[1] == "1234:11e8" }) else {
      print("devices-test: FAILED: no edu device (QEMU needs -device edu)")
      exit(1)
    }
    check(edu[4] == "running", "edu's driver host is running")
    check(edu[3].utf8.starts(with: "edu-".utf8), "edu's driver host is bin/edu")

    guard let driver = read(ns, "/svc/devmgr/drivers/\(edu[3])/status") else {
      print("devices-test: FAILED: reading the driver's tree")
      exit(1)
    }
    print("devices-test: \(edu[3]): \(driver)", terminator: "")
    let words = driver.split(separator: "\n").first.map { $0.split(separator: " ").map(String.init) } ?? []
    check(!words.contains("FAILED"), "the driver's checks")
    check(words.contains("3628800,"), "the device's factorial")
    check(words.contains("confined"), "the driver's resource is its BAR")
    if let e = read(ns, "/svc/devmgr/enumeration") { print("devices-test: enumeration: \(e)", terminator: "") }
    print("devices-test: ok")
  }
}
