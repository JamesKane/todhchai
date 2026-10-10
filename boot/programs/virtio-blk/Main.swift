// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-blk (M3i): the driver host for a virtio block device over
// PCI, modern or transitional (lib/virtio). It negotiates features and
// reads the disk's size. Requests need the device to reach memory, through
// a BTI (croi's K9e): until then it stops there, its queues unset, and
// says so in `status` (virtio-host/Host.swift serves it).

import Sys
import Virtio

@main struct VirtioBlock {
  static func main() {
    runDriver("virtio-blk") { pci throws(Status) in
      var lines: [String] = []
      let device = pci.device
      let features = try negotiate(device, Block.Feature.blockSize | Block.Feature.flush | Block.Feature.readOnly, &lines)
      let g = Block.geometry(device)
      if features & Block.Feature.readOnly != 0 { lines.append("read-only") }
      lines.append("capacity \(g.sectors) sectors (\(g.sectors * 512 / 1_048_576) MiB), block \(g.blockSize)")
      lines.append("queues \(device.queueCount), queue 0 up to \(device.queueSize(0)) entries")
      lines.append("requests wait for DMA: a BTI (croi K9e)")
      return lines
    }
  }
}
