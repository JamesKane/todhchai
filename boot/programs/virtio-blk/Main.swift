// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-blk (M3i): the block service over a virtio block device on
// PCI, modern or transitional. It opens the device (lib/virtio), takes
// memory the device reaches through its BTI (croi K9e: contiguous VMOs,
// pinned), and serves the block service (Services.block) over
// VirtioBlockBackend: requests through queue 0, each completion its
// device's INTx interrupt (routed by devmgr through ACPI), read from a port
// with a deadline so a lost interrupt costs a poll, not a hang. Its tree
// is the block service's: `device` (BlockIPC.Device) and `status`.
//
// A device it can't drive (no BTI, no interrupt) is reported through the
// shared scaffold's `status` instead (virtio-host/Host.swift).

import Block
import DevMgr
import Launch
import LibSys
import Services
import Sys
import Virtio

@main struct VirtioBlock {
  static func main() {
    var resources = DeviceResources(take: StartupHandles.take)
    guard let bti = resources.takeBTI(), let irq = try? resources.interrupt(), let pci = try? PCIDevice(resources),
      let notify = pci.notify, let isr = pci.isr, let port = try? Port.create(bindToInterrupt: true),
      (try? Interrupt.bind(irq, port: port, key: 1)) != nil
    else {
      probeOnly(resources)
    }
    // INTx on: the command register's Interrupt Disable off.
    if let config = try? resources.mapConfig() { config.store16(4, config.load16(4) & ~UInt16(0x400)) }
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)), let start = try? Startup(Handle(raw: raw))
    else { exit(2) }

    final class Counts: @unchecked Sendable {
      var interrupts = 0
      var timeouts = 0
    }
    let counts = Counts()
    let irqRaw = irq.release(), portRaw = port.release()
    let backend: VirtioBlockBackend<BARWindow>
    do throws(Status) {
      backend = try VirtioBlockBackend(device: pci.device, notify: notify, multiplier: pci.notifyMultiplier,
                                       memory: PinnedMemory(bti: bti)) {
        let port = Handle(raw: portRaw), irq = Handle(raw: irqRaw)
        if (try? Port.wait(port, deadline: Clock.monotonic() + 50_000_000)) != nil {
          counts.interrupts += 1
        } else {
          counts.timeouts += 1
        }
        _ = isr.read(0, width: 1)  // the line goes down
        try? Interrupt.ack(irq)
        _ = port.release()
        _ = irq.release()
      }
    } catch {
      print("virtio-blk: can't start the device: status \(error.rawValue)")
      exit(1)
    }
    let name = "virtio-blk \(backend.blockCount * 4096 / 1_048_576) MiB"
    print("virtio-blk: \(name), features \(String(backend.features, radix: 16)), serving the block service")
    do {
      try Services.block(start, backend: backend, name: name)
    } catch {
      exit(1)
    }
    _ = consume resources
  }

  /// A device it can't drive: negotiate, report, and serve the status.
  static func probeOnly(_ resources: consuming DeviceResources) -> Never {
    runDriver("virtio-blk", resources) { pci throws(Status) in
      var lines: [String] = []
      let device = pci.device
      _ = try negotiate(device, Block.Feature.blockSize | Block.Feature.flush | Block.Feature.readOnly, &lines)
      let g = Block.geometry(device)
      lines.append("capacity \(g.sectors) sectors (\(g.sectors * 512 / 1_048_576) MiB), block \(g.blockSize)")
      lines.append("not driven: no BTI or no interrupt")
      return lines
    }
  }
}
