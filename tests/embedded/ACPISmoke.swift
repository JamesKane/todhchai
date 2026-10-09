// SPDX-License-Identifier: BSD-3-Clause

// TDACPI built as Embedded Swift on the host: a table's header and
// checksum, and a tiny DSDT loaded (tests/acpi runs the rest).

import TDACPI

@main struct ACPISmoke {
  static func main() {
    // A DSDT with one byte of AML, revision 2, checksum filled in.
    var t: [UInt8] = [0x44, 0x53, 0x44, 0x54, 37, 0, 0, 0, 2, 0]
    t += [UInt8](repeating: 0x41, count: 26)
    t.append(0x08)
    var sum: UInt8 = 0
    for b in t { sum &+= b }
    t[9] = 0 &- sum
    guard let table = try? Table(t) else { fatalError("the table didn't read") }
    check(table.signature == .dsdt && table.revision == 2 && table.body.count == 1, "the header")
    t[36] = 0x09
    check((try? Table(t)) == nil, "a bad checksum is caught")
    // Device (\_SB.DEV) { Name (_HID, 0x1234) }, loaded.
    let aml: [UInt8] = [0x5B, 0x82, 0x13, 0x5C, 0x2E, 0x5F, 0x53, 0x42, 0x5F, 0x44, 0x45, 0x56, 0x5F,
                        0x08, 0x5F, 0x48, 0x49, 0x44, 0x0B, 0x34, 0x12]
    var d: [UInt8] = [0x44, 0x53, 0x44, 0x54, UInt8(36 + aml.count), 0, 0, 0, 2, 0]
    d += [UInt8](repeating: 0x41, count: 26)
    d += aml
    sum = 0
    for b in d { sum &+= b }
    d[9] = 0 &- sum
    var ns = Namespace()
    guard let dsdt = try? Table(d), (try? ns.load(dsdt)) != nil else { fatalError("the DSDT didn't load") }
    check(ns.lookup("\\_SB.DEV._HID") != nil, "the device and its _HID are in the namespace")
    print("embedded TDACPI: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
