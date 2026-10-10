// SPDX-License-Identifier: BSD-3-Clause

// bin/edu (M3g): the driver host for QEMU's `edu` teaching device (QEMU's
// docs/specs/edu.rst), the first that devmgr starts. It is given BAR 0 and
// its configuration space as resources and nothing else, and proves both:
// the identification register (0x00: major, minor, 0xED), the liveness
// check (0x04 reads back the inverse of what was written), a factorial
// the device computes (0x08, busy while bit 0 of 0x20 is set), the
// function's ids through its configuration space, and that its resource
// reaches no further than its BAR. Then its interrupt (M3i, croi's K9c),
// routed by devmgr through ACPI: 100 times the device raises it (0x60),
// the driver takes it in interrupt_wait and lowers it (0x64), timing
// raise-to-wake and fire-to-wake. Its tree's `status` says what it found.

import DevMgr
import IPC
import Launch
import LibSys
import Node
import Sys

@main struct Edu {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    let device = DeviceResources(take: StartupHandles.take)
    var start: Startup
    do { start = try Startup(Handle(raw: raw)) } catch { exit(2) }

    var findings: [String] = []
    var ok = true
    do throws(Status) {
      let bar = try device.bar(0)
      let regs = try device.map(bar: 0)
      let id = regs.load32(0x00)
      ok = ok && id & 0xFF == 0xED
      findings.append("edu \(id >> 24).\((id >> 16) & 0xFF)")
      regs.store32(0x04, 0x1234_5678)
      let live = regs.load32(0x04) == ~UInt32(0x1234_5678)
      ok = ok && live
      findings.append(live ? "live" : "not live")
      regs.store32(0x08, 10)
      let deadline = Clock.monotonic() + 1_000_000_000
      while regs.load32(0x20) & 1 != 0, Clock.monotonic() < deadline {}
      let factorial = regs.load32(0x08)
      ok = ok && factorial == 3_628_800
      findings.append("10! = \(factorial)")
      let config = try device.mapConfig()
      let vendor = config.load16(0), product = config.load16(2)
      ok = ok && vendor == 0x1234 && product == 0x11E8
      findings.append("config \(vendor == 0x1234 && product == 0x11E8 ? "1234:11e8" : "wrong")")
      findings.append("bars \(device.barIndices.map { "\($0)" }.joined(separator: ","))")
      // Nothing past the BAR: a VMO over the next page is refused.
      let confined: Bool
      do throws(Status) {
        _ = try device.borrowedBAR(0) { (h: borrowing Handle) throws(Status) in
          try VMO.physical(resource: h, address: bar.base + bar.size, size: 4096)
        }
        confined = false
      } catch {
        confined = error == .outOfRange
      }
      ok = ok && confined
      findings.append(confined ? "confined" : "not confined")

      // The interrupt: INTx on (the command register's Interrupt Disable off).
      config.store16(4, config.load16(4) & ~UInt16(0x400))
      let gsi = try device.interruptNumber()
      let irq = try device.interrupt()
      var raiseToWake: [Int64] = [], fireToWake: [Int64] = []
      for _ in 0..<100 {
        let t0 = Clock.monotonic()
        regs.store32(0x60, 1)
        let fired = try Interrupt.wait(irq)
        let t1 = Clock.monotonic()
        guard regs.load32(0x24) & 1 == 1 else { throw .badState }
        regs.store32(0x64, 1)  // the line goes down; the next wait unmasks it
        raiseToWake.append(t1 - t0)
        fireToWake.append(t1 - fired)
      }
      raiseToWake.sort()
      fireToWake.sort()
      let mode = switch device.interruptMode {
      case .levelHigh: "level-high"
      case .levelLow: "level-low"
      case .edgeHigh: "edge-high"
      case .edgeLow: "edge-low"
      case .default, .none: "default"
      }
      findings.append("irq \(gsi) \(mode) 100 taken, raise to wake \(raiseToWake[50] / 1000) us, fire to wake \(fireToWake[50] / 1000) us")
    } catch {
      ok = false
      findings.append("failed: \(error)")
    }
    let status = findings.joined(separator: ", ") + (ok ? "" : " FAILED") + "\n"
    print("edu: \(status)", terminator: "")

    do {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { status })
      try tree.serve(try start.export())
      try start.ready()
      try dispatcher.run()
    } catch {
      exit(1)
    }
  }
}
