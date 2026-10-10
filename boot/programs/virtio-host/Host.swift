// SPDX-License-Identifier: BSD-3-Clause

// What every virtio driver host does around its device (M3i, M3k),
// compiled into each: reads its Startup and the resources devmgr granted,
// opens the device (lib/virtio's PCIDevice), lets the driver `probe` it
// for its status lines, prints them, and serves them as its tree's
// `status` until the launcher ends it. A probe that throws is reported
// in the status as FAILED.

import DevMgr
import IPC
import Launch
import LibSys
import Node
import Sys
import Virtio

func runDriver(_ name: String, _ probe: (PCIDevice) throws(Status) -> [String]) -> Never {
  runDriver(name, DeviceResources(take: StartupHandles.take), probe)
}

/// The same, with the device's resources already taken.
func runDriver(_ name: String, _ resources: consuming DeviceResources, _ probe: (PCIDevice) throws(Status) -> [String])
  -> Never
{
  guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
  var start: Startup
  do { start = try Startup(Handle(raw: raw)) } catch { exit(2) }

  var lines: [String] = []
  do throws(Status) {
    let pci = try PCIDevice(resources)
    lines.append("capabilities \(pci.summary)")
    lines += try probe(pci)
  } catch {
    lines.append("FAILED: status \(error.rawValue)")
  }
  let status = lines.joined(separator: "\n") + "\n"
  print("\(name): " + lines.joined(separator: "; "))
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
  _ = consume resources
  exit(0)
}

/// Negotiates `wanted`, a failure reported as a status line and thrown.
func negotiate(_ device: Virtio.Device<BARWindow>, _ wanted: UInt64, _ lines: inout [String]) throws(Status) -> UInt64 {
  do throws(VirtioError) {
    let features = try device.negotiate(wanted)
    lines.append("features \(String(features, radix: 16))")
    return features
  } catch {
    lines.append("negotiation failed: \(error == .notModern ? "not modern" : "features refused")")
    throw Status.notSupported
  }
}

let waitsForDMA = "queues wait for DMA: a BTI (croi K9e)"
