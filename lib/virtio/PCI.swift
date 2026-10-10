// SPDX-License-Identifier: BSD-3-Clause

// A virtio device as a driver host has it (M3i, M3k): its configuration
// space and BARs from devmgr's grants (DeviceResources), the vendor
// capabilities found in the former, and windows into the latter for the
// common and device configurations. Only the BARs the capabilities name
// are mapped; the PCI configuration access capability is used through
// configuration space, never mapped.

import DevMgr
import Sys

/// A mapped BAR, shared by the windows into it.
public final class MappedBAR {
  public let index: Int
  let regs: Registers
  init(index: Int, regs: consuming Registers) {
    self.index = index
    self.regs = regs
  }
}

/// A capability's range in its BAR, as a `Window`.
public final class BARWindow: Window {
  let bar: MappedBAR
  let base: Int
  init(_ bar: MappedBAR, base: Int) {
    self.bar = bar
    self.base = base
  }
  public func read(_ offset: Int, width: Int) -> UInt64 {
    let o = base + offset
    switch width {
    case 1: return UInt64(bar.regs.load8(o))
    case 2: return UInt64(bar.regs.load16(o))
    case 4: return UInt64(bar.regs.load32(o))
    default: return UInt64(bar.regs.load32(o)) | UInt64(bar.regs.load32(o + 4)) << 32
    }
  }
  public func write(_ offset: Int, width: Int, _ value: UInt64) {
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

/// The device a driver host was given, opened.
public final class PCIDevice {
  public let capabilities: [Capability]
  public let bars: [MappedBAR]
  public let device: Device<BARWindow>
  /// Where queues are notified (§4.1.4.4): queue_notify_off times
  /// `notifyMultiplier` into this window.
  public let notify: BARWindow?
  public let notifyMultiplier: UInt32

  public init(_ resources: borrowing DeviceResources) throws(Status) {
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
    guard let common = window(.common) else { throw .notSupported }
    // A device with no configuration of its own gets an empty window.
    let device = window(.device) ?? common
    notify = window(.notify)
    notifyMultiplier = caps.first { $0.kind == .notify }?.multiplier ?? 0
    capabilities = caps
    self.bars = bars
    self.device = Device(common: common, device: device)
  }

  /// `kind@barN` for each capability, for a status line.
  public var summary: String { capabilities.map { "\($0.kind.rawValue)@bar\($0.bar)" }.joined(separator: " ") }
}
