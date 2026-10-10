// SPDX-License-Identifier: BSD-3-Clause

// PCI built as Embedded Swift on the host: ECAM over a buffer holding one
// bus, a function found in it through volatile accesses (tests/pci runs
// the rest).

import PCI

@main struct PCISmoke {
  static func main() {
    let size = ECAM.size(buses: 1)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
    unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0xFF, count: size)
    // 00:04.0: edu's ids, class 00.ff.00, a device header, no capabilities.
    let at = ECAM.offset(bus: 0, device: 4, function: 0)
    unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    unsafe (buffer + at).initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    unsafe buffer.storeBytes(of: UInt32.max, as: UInt32.self)  // no 00:00.0
    unsafe (buffer + at).storeBytes(of: UInt32(0x11E8_1234), as: UInt32.self)
    unsafe (buffer + at + Register.subclass).storeBytes(of: UInt8(0xFF), as: UInt8.self)
    let ecam = unsafe ECAM(unsafe: buffer, endBus: 0)
    let found = enumerate(ecam)
    check(found.count == 1, "one function")
    check(found.first?.description.utf8.elementsEqual("00:04.0 1234:11e8 class 00.ff.00".utf8) == true, "its identity")
    unsafe buffer.deallocate()
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError("pci-smoke: \(what)") }
  }
}
