// SPDX-License-Identifier: BSD-3-Clause

// devmgr's bind rules, and the manifest directives that give it hardware
// and programs (M3g).

import DevMgr
import Launch
import PCI
import Testing

func function(_ vendor: UInt16, _ device: UInt16, at d: UInt8) -> Function {
  Function(address: FunctionAddress(bus: 0, device: d, function: 0), vendor: vendor, device: device, classCode: 0,
           subclass: 0, progIF: 0, revision: 0, headerType: 0, subsystemVendor: 0, subsystem: 0, interruptPin: 0,
           bars: [], capabilities: [], secondaryBus: nil)
}

@Test func firstMatchingRuleBinds() {
  let devices = [Device(pci: function(0x8086, 0x29C0, at: 0)), Device(pci: function(0x1234, 0x11E8, at: 4)),
                 Device(pci: function(0x1AF4, 0x1044, at: 3))]  // virtio-rng: no built-in rule
  let rules = Drivers.rules + [
    DriverRule(program: "any-virtio") { $0.pci?.vendor == 0x1AF4 },
    DriverRule(program: "never") { _ in true },
  ]
  let bound = bind(devices, rules)
  #expect(bound.map { $0.map { rules[$0].program } } == ["never", "edu", "any-virtio"])
  #expect(devices[1].name == "pci-00:04.0")
  #expect(bind(devices, Drivers.rules).map { $0 != nil } == [false, true, false])
}

@Test func resourceAndProgramsDirectives() throws {
  let m = try Manifest(file: "devmgr.manifest", text: """
    service devmgr
    program devmgr
    resource mmio
    resource ioport
    programs
    export
    """)
  #expect(m.resources.map { $0.kind } == [.mmio, .ioport])
  #expect(m.resources.map { $0.line } == [3, 4])
  #expect(m.programsLine == 5)
  for (text, message) in [
    ("resource dma", "devmgr.manifest:3: 'resource' takes mmio, irq, ioport, smc or system"),
    ("resource mmio\nresource mmio", "devmgr.manifest:4: a second 'resource mmio'"),
    ("programs bin", "devmgr.manifest:3: 'programs' takes 0 arguments"),
  ] {
    #expect(throws: LaunchError(message)) { try Manifest(file: "devmgr.manifest", text: "service devmgr\nprogram devmgr\n\(text)") }
  }
}
