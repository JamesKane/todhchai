// SPDX-License-Identifier: BSD-3-Clause

// Runs IPCWire built as Embedded Swift on the host. The first failed check
// traps, and ctest reports the test as failed.

import IPCWire

@main struct WireSmoke {
  static func main() {
    check(wireAligned(0) == 0, "aligned 0")
    check(wireAligned(1) == 8, "aligned 1")
    check(wireAligned(9) == 16, "aligned 9")
    print("embedded IPCWire: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
