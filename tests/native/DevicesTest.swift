// SPDX-License-Identifier: BSD-3-Clause

// bin/devices-test: devmgr's test on croi (M3g), a client the launcher
// starts beside devmgr (tests/native/devices). Run by
//
//     td boot --test --manifests tests/native/devices --cmdline launcher.until=devices-test -- -device edu \
//       -blockdev driver=null-co,node-name=t,size=67108864 -device virtio-blk-pci,drive=t,disable-legacy=on \
//       ... and QEMU's other virtio devices (td ci's step `devices-amd64` has them all)
//
// It reads devmgr's status through /svc: q35's host bridge and the ESP's
// virtio-blk are found and left unbound, the edu device is bound to bin/edu
// and running, and ACPI's devices from q35's DSDT are there (M3h); then
// reads the edu driver host's own tree through devmgr's, where the driver
// reports what it did with the device it was given.

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
    // virtio-blk (M3i): the test disk (QEMU's null-co, 64 MiB, modern only)
    // negotiated and sized.
    guard let disk = lines.first(where: { $0[1] == "1af4:1042" }) else {
      print("devices-test: FAILED: no modern virtio-blk (td ci adds -device virtio-blk-pci,disable-legacy=on)")
      exit(1)
    }
    check(disk[3].utf8.starts(with: "virtio-blk-".utf8) && disk[4] == "running", "virtio-blk's driver host")
    let blk = read(ns, "/svc/devmgr/drivers/\(disk[3])/status") ?? ""
    for line in blk.split(separator: "\n") { print("devices-test: \(disk[3]): \(line)") }
    check(blk.split(separator: "\n").contains("capacity 131072 sectors (64 MiB), block 512"), "the disk's size")
    // The other virtio devices (M3k), each driver's status read through devmgr.
    func driverStatus(_ ids: String, nth: Int = 0) -> [String] {
      let found = lines.filter { $0[1] == ids }
      guard nth < found.count, found[nth][4] == "running" else { return [] }
      return (read(ns, "/svc/devmgr/drivers/\(found[nth][3])/status") ?? "").split(separator: "\n").map(String.init)
    }
    check(driverStatus("1af4:1041").contains("mac 52:54:00:12:34:56"), "virtio-net's MAC")
    let inputs = [driverStatus("1af4:1052", nth: 0), driverStatus("1af4:1052", nth: 1)]
    check(inputs.contains { $0.contains("name QEMU Virtio Keyboard") } && inputs.contains { $0.contains("name QEMU Virtio Tablet") },
          "virtio-input's keyboard and tablet")
    check(driverStatus("1af4:1050").contains { $0.utf8.starts(with: "scanouts 1,".utf8) }, "virtio-gpu's scanout")
    check(driverStatus("1af4:1059").contains { $0.utf8.starts(with: "jacks 0, streams 2,".utf8) }, "virtio-sound's streams")
    // ACPI's devices, from q35's DSDT through croi's boot data (M3h).
    check(lines.contains { $0[0] == "acpi-_SB_.PCI0" && $0[1] == "PNP0A08" }, "ACPI's PCI root bridge")
    check(lines.contains { $0[0] == "acpi-_SB_.PCI0.SF8_.RTC_" && $0[1] == "PNP0B00" }, "ACPI's RTC")
    check(lines.filter { $0[1] == "PNP0C0F" }.count == 16, "ACPI's interrupt links")
    check(edu[3].utf8.starts(with: "edu-".utf8), "edu's driver host is bin/edu")

    guard let driver = read(ns, "/svc/devmgr/drivers/\(edu[3])/status") else {
      print("devices-test: FAILED: reading the driver's tree")
      exit(1)
    }
    print("devices-test: \(edu[3]): \(driver)", terminator: "")
    let words = driver.split(separator: "\n").first.map {
      $0.split(separator: " ").map { String(decoding: $0.utf8.filter { $0 != UInt8(ascii: ",") }, as: UTF8.self) }
    } ?? []
    check(!words.contains("FAILED"), "the driver's checks")
    check(words.contains("3628800"), "the device's factorial")
    check(words.contains("confined"), "the driver's resource is its BAR")
    check(words.contains("taken"), "the device's interrupt, routed through ACPI's _PRT")
    if let e = read(ns, "/svc/devmgr/enumeration") { print("devices-test: enumeration: \(e)", terminator: "") }
    guard let acpi = read(ns, "/svc/devmgr/acpi") else {
      print("devices-test: FAILED: reading /svc/devmgr/acpi")
      exit(1)
    }
    for line in acpi.split(separator: "\n") { print("devices-test: acpi: \(line)") }
    // The console (M3j): text written to it is on the screen, below the
    // system's log.
    if var w = try? ns.open("/svc/console/write") { _ = try? w.writeText("dia duit ─ devices-test\n") }
    // The console reads the log on a thread of its own: give it a moment.
    var shown: [String] = []
    var showsLog = false, showsText = false
    let deadline = Clock.monotonic() + 2_000_000_000
    while Clock.monotonic() < deadline {
      shown = (read(ns, "/svc/console/screen") ?? "").split(separator: "\n").map(String.init)
      showsText = shown.contains("dia duit ─ devices-test")
      showsLog = shown.contains { $0.utf8.starts(with: "[".utf8) && $0.split(separator: " ").contains("devices-test:") }
      if showsText && showsLog { break }
      sleep(until: Clock.monotonic() + 20_000_000)
    }
    let cstatus = read(ns, "/svc/console/status") ?? ""
    for line in cstatus.split(separator: "\n") { print("devices-test: console: \(line)") }
    check(showsText, "the console shows what is written to it")
    check(showsLog, "the console shows the log")
    print("devices-test: ok")
  }
}
