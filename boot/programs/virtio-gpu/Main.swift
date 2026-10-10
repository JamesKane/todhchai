// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-gpu (M3k): the driver host for a virtio GPU (Virtual I/O
// Device 1.2 §5.7), the 2D part: it negotiates EDID and reads how many
// scanouts the device has. Display modes, resources and scanout come by
// command through the control queue once the device can reach memory
// (croi's K9e), for M4's display service.

import Sys
import Virtio

@main struct VirtioGPU {
  static func main() {
    runDriver("virtio-gpu") { pci throws(Status) in
      var lines: [String] = []
      let d = pci.device
      let features = try negotiate(d, GPU.Feature.edid, &lines)
      let c = GPU.config(d)
      lines.append("scanouts \(c.scanouts), capsets \(c.capsets)\(features & GPU.Feature.edid != 0 ? ", edid" : "")")
      lines.append(waitsForDMA)
      return lines
    }
  }
}
