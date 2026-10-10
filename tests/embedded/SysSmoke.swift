// SPDX-License-Identifier: BSD-3-Clause

// Sys built as Embedded Swift on the host, over the stub backend: croi's
// flow ids, and every call failing cleanly until croi's syscalls (M3).
// tests/sys runs Sys over the hosted kernel.

import Sys

@main struct SysSmoke {
  static func main() {
    check(flowID(channel: 1024, txid: 1) == 0x9d61_a03a_3cfc_0647, "flow id")
    check(Status.badHandle.rawValue == -11 && Rights.channelDefault.rawValue == 0xF00E, "values")
    var status = Status.ok
    do throws(Status) {
      _ = try Channel.create()
    } catch {
      status = error
    }
    check(status == .notSupported, "stub")
    print("embedded Sys: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
