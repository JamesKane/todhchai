// SPDX-License-Identifier: BSD-3-Clause

// The D-Bus marshalling RealtimeKit's request uses, against the
// specification's alignment rules.

import Glibc
@testable import Todhchai
import Testing

@Test func dbusValuesAlignAndRoundTrip() {
  var w = DBusWriter()
  w.bytes = [1]  // one byte in: the next u32 pads to 4, the u64 to 8
  w.put(.uint32(0x0102_0304))
  w.put(.uint64(7))
  w.put(.string("ab"))
  w.put(.variant(.int32(-2)))
  #expect(w.bytes[0..<8] == [1, 0, 0, 0, 4, 3, 2, 1])
  #expect(w.bytes[8..<16] == [7, 0, 0, 0, 0, 0, 0, 0])
  #expect(w.bytes[16..<23] == [2, 0, 0, 0, 0x61, 0x62, 0])  // length, bytes, NUL
  #expect(w.bytes[23..<26] == [1, 0x69, 0])  // the variant's signature "i"
  #expect(w.bytes[28..<32] == [0xFE, 0xFF, 0xFF, 0xFF])  // aligned to 4 from the message's start
  var r = DBusReader(bytes: w.bytes, at: 1)
  #expect(r.value("u") == .uint32(0x0102_0304))
  #expect(r.value("t") == .uint64(7))
  #expect(r.value("s") == .string("ab"))
  #expect(r.value("v") == .variant(.int32(-2)))
}

/// A real request to RealtimeKit, from a fresh thread. Runs only with
/// TODHCHAI_LIVE_AUDIO=1 (it changes a thread's scheduling on the desktop).
@Test(.enabled(if: getenv("TODHCHAI_LIVE_AUDIO") != nil))
func realtimeKitGrantsARealtimeThread() throws {
  let t = try Thread.spawn(intent: .realtime(period: .milliseconds(3), budget: .milliseconds(1), deadline: .milliseconds(3))) {}
  #expect([Admission.deadline, .fixedPriority, .fixedPriorityViaRealtimeKit].contains(t.admission))
  t.join()
}
