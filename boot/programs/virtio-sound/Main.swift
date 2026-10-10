// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-sound (M3k): the driver host for a virtio sound device
// (Virtual I/O Device 1.2 §5.14). It reads how many jacks, PCM streams
// and channel maps the device has; querying them and playing go through
// its queues once the device can reach memory (croi's K9e), for M4's
// audio service.

import Sys
import Virtio

@main struct VirtioSound {
  static func main() {
    runDriver("virtio-sound") { pci throws(Status) in
      var lines: [String] = []
      let d = pci.device
      _ = try negotiate(d, Sound.Feature.controls, &lines)
      let c = Sound.config(d)
      lines.append("jacks \(c.jacks), streams \(c.streams), channel maps \(c.channelMaps)\(c.controls.map { ", controls \($0)" } ?? "")")
      lines.append(waitsForDMA)
      return lines
    }
  }
}
