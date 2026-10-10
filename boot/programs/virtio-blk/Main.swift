// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-blk (M3i): the driver host for a virtio block device over
// PCI, modern or transitional (lib/virtio). It finds the device's virtio
// capabilities in its configuration space, maps the BARs they name (only
// those devmgr granted), negotiates features and reads the disk's size.
// Requests need the device to reach memory, through a BTI (croi's K9e):
// until then it stops there, its queues unset, and says so in `status`.

import DevMgr
import IPC
import Launch
import LibSys
import Node
import Sys
import Virtio

/// A mapped BAR, shared by the windows into it.
final class MappedBAR {
  let index: Int
  let regs: Registers
  init(index: Int, regs: consuming Registers) {
    self.index = index
    self.regs = regs
  }
}

/// A capability's range in its BAR.
final class BARWindow: Window {
  let bar: MappedBAR
  let base: Int
  init(_ bar: MappedBAR, base: Int) {
    self.bar = bar
    self.base = base
  }
  func read(_ offset: Int, width: Int) -> UInt64 {
    let o = base + offset
    switch width {
    case 1: return UInt64(bar.regs.load8(o))
    case 2: return UInt64(bar.regs.load16(o))
    case 4: return UInt64(bar.regs.load32(o))
    default: return UInt64(bar.regs.load32(o)) | UInt64(bar.regs.load32(o + 4)) << 32
    }
  }
  func write(_ offset: Int, width: Int, _ value: UInt64) {
    let o = base + offset
    switch width {
    case 1: bar.regs.store8(o, UInt8(truncatingIfNeeded: value))
    case 2: bar.regs.store16(o, UInt16(truncatingIfNeeded: value))
    case 4: bar.regs.store32(o, UInt32(truncatingIfNeeded: value))
    default:
      bar.regs.store32(o, UInt32(truncatingIfNeeded: value))
      bar.regs.store32(o + 4, UInt32(truncatingIfNeeded: value >> 32))
    }
  }
}

@main struct VirtioBlock {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    let resources = DeviceResources(take: StartupHandles.take)
    var start: Startup
    do { start = try Startup(Handle(raw: raw)) } catch { exit(2) }

    var lines: [String] = []
    var ok = true
    do throws(Status) {
      // The capability list, through the configuration space.
      let config = try resources.mapConfig()
      var list: [Int] = []
      if config.load16(0x06) & 0x10 != 0 {
        var next = Int(config.load8(0x34) & 0xFC)
        while next >= 0x40, list.count < 48 {
          list.append(next)
          next = Int(config.load8(next + 1) & 0xFC)
        }
      }
      let caps = Capability.find(at: list) { config.load8($0) }
      // The BARs they name, each mapped once (not the PCI configuration
      // access capability's, which is used through configuration space).
      var bars: [MappedBAR] = []
      for c in caps where c.kind != .pci && !bars.contains(where: { $0.index == c.bar }) {
        bars.append(MappedBAR(index: c.bar, regs: try resources.map(bar: c.bar)))
      }
      func window(_ kind: Capability.Kind) -> BARWindow? {
        guard let c = caps.first(where: { $0.kind == kind }), let b = bars.first(where: { $0.index == c.bar }) else {
          return nil
        }
        return BARWindow(b, base: Int(c.offset))
      }
      guard let common = window(.common), let deviceConfig = window(.device) else {
        throw Status.notSupported
      }
      lines.append("capabilities \(caps.map { "\($0.kind.rawValue)@bar\($0.bar)" }.joined(separator: " "))")
      let device = Device(common: common, device: deviceConfig)
      let features: UInt64
      do throws(VirtioError) {
        features = try device.negotiate(Block.Feature.blockSize | Block.Feature.flush | Block.Feature.readOnly)
      } catch {
        lines.append("negotiation failed: \(error == .notModern ? "not modern" : "features refused")")
        throw Status.notSupported
      }
      let g = Block.geometry(device)
      lines.append("features \(String(features, radix: 16))\(features & Block.Feature.readOnly != 0 ? " read-only" : "")")
      lines.append("capacity \(g.sectors) sectors (\(g.sectors * 512 / 1_048_576) MiB), block \(g.blockSize)")
      lines.append("queues \(device.queueCount), queue 0 up to \(device.queueSize(0)) entries")
      lines.append("requests wait for DMA: a BTI (croi K9e)")
    } catch {
      ok = false
      lines.append("FAILED: status \(error.rawValue)")
    }
    let status = lines.joined(separator: "\n") + "\n"
    print("virtio-blk: " + lines.joined(separator: "; "))

    do {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { status })
      try tree.serve(try start.export())
      try start.ready()
      _ = try? dispatcher.run()
    } catch {
      exit(1)
    }
    _ = ok
  }
}
