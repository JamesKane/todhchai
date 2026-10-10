// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-net (M3k): the driver host for a virtio network device
// (Virtual I/O Device 1.2 §5.1). It negotiates the MAC address, link
// status, MTU and multiqueue, and reads them; packets need the device to
// reach memory (croi's K9e), and the network stack is M4's.

import Sys
import Virtio

@main struct VirtioNet {
  static func main() {
    runDriver("virtio-net") { pci throws(Status) in
      var lines: [String] = []
      let d = pci.device
      _ = try negotiate(d, Network.Feature.mac | Network.Feature.status | Network.Feature.mtu | Network.Feature.multiqueue,
                        &lines)
      let c = Network.config(d)
      lines.append("mac \(c.mac.map { Network.text($0) } ?? "none")")
      lines.append("link \(c.status.map { $0 & 1 != 0 ? "up" : "down" } ?? "unknown")")
      lines.append("mtu \(c.mtu.map { "\($0)" } ?? "default"), queue pairs \(c.queuePairs), queues \(d.queueCount)")
      lines.append(waitsForDMA)
      return lines
    }
  }
}
