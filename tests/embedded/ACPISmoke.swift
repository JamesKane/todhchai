// SPDX-License-Identifier: BSD-3-Clause

// TDACPI built as Embedded Swift on the host: a table's header and
// checksum (tests/acpi runs the rest).

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
    print("embedded TDACPI: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
