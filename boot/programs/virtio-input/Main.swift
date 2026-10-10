// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-input (M3k): the driver host for a virtio input device
// (Virtual I/O Device 1.2 §5.8): keyboards, mice, tablets. It asks the
// configuration for the device's name, ids and the event types it
// reports; the events themselves come through a queue once the device can
// reach memory (croi's K9e), for M4's input service.

import Sys
import Virtio

@main struct VirtioInput {
  static func main() {
    runDriver("virtio-input") { pci throws(Status) in
      var lines: [String] = []
      let d = pci.device
      _ = try negotiate(d, 0, &lines)
      let id = Input.identity(d)
      lines.append("name \(id.name)")
      lines.append("ids bus \(id.bus) vendor \(id.vendor) product \(id.product) version \(id.version)")
      lines.append("events \(id.eventTypes.map { "\($0)" }.joined(separator: ","))")
      lines.append(waitsForDMA)
      return lines
    }
  }
}
