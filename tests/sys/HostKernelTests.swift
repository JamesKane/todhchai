// SPDX-License-Identifier: BSD-3-Clause

import Sys
import SysHost
import SysHostCTests
import Testing

/// Runs `body` and checks that it throws exactly `expected`.
func expectStatus(_ expected: Status, _ body: () throws(Status) -> Void,
                  sourceLocation: SourceLocation = #_sourceLocation) {
  var got = Status.ok
  do throws(Status) { try body() } catch { got = error }
  #expect(got == expected, sourceLocation: sourceLocation)
}

@Test func cClientRoundTrip() { #expect(host_c_channel_round_trip() == 0) }
@Test func cClientReadTooSmall() { #expect(host_c_read_too_small() == 0) }
@Test func cClientHandleMoves() { #expect(host_c_handle_moves() == 0) }

@Test func swiftChannelCarriesBytesAndHandles() throws {
  let ends = try Channel.create()
  let a = ends.a, b = ends.b
  let event = try Event.create()
  try Channel.write(a, bytes: [1, 2, 3], handles: [event.release()])
  _ = try wait(b, for: Signals.readable)
  let message = try Channel.read(b)
  #expect(message.bytes == [1, 2, 3])
  #expect(message.handles.count == 1)
  let moved = Handle(raw: message.handles[0])
  try signal(moved, set: Signals.signaled)
  let observed = try wait(moved, for: Signals.signaled, deadline: 0)
  #expect(observed & Signals.signaled != 0)
}

@Test func readOnEmptyChannelShouldWait() throws {
  let ends = try Channel.create()
  let b = ends.b
  expectStatus(Status.shouldWait) { () throws(Status) in try Channel.read(b) }
}

@Test func closingAnEndSignalsThePeer() throws {
  let ends = try Channel.create()
  let a = ends.a, b = ends.b
  _ = consume a
  let observed = try wait(b, for: Signals.peerClosed, deadline: 0)
  #expect(observed & Signals.peerClosed != 0)
  expectStatus(Status.peerClosed) { () throws(Status) in try Channel.write(b, bytes: [0]) }
}

@Test func waitTimesOutAtTheDeadline() throws {
  let event = try Event.create()
  let deadline = HostKernel.now() + 5_000_000
  expectStatus(Status.timedOut) { () throws(Status) in try wait(event, for: Signals.signaled, deadline: deadline) }
  #expect(HostKernel.now() >= deadline)
}

@Test func waitWakesWhenAnotherThreadSignals() async throws {
  let event = try Event.create()
  let raw = event.raw
  let signaller = Task.detached {
    try? await Task.sleep(nanoseconds: 2_000_000)
    try? HostKernel.shared.signal(raw, clear: 0, set: Signals.signaled)
  }
  let observed = try wait(event, for: Signals.signaled)
  #expect(observed & Signals.signaled != 0)
  await signaller.value
}

@Test func staleHandlesAreRejected() throws {
  let event = try Event.create()
  let raw = event.release()
  try HostKernel.shared.close(raw)
  let again = try Event.create()  // likely reuses the slot, with a new generation
  let againRaw = again.raw
  #expect(againRaw != raw)
  expectStatus(Status.badHandle) { () throws(Status) in try HostKernel.shared.signal(raw, clear: 0, set: Signals.signaled) }
}

@Test func signalOnlyChangesSettableSignals() throws {
  let ends = try Channel.create()
  let a = ends.a
  expectStatus(Status.invalidArgs) { () throws(Status) in try signal(a, set: Signals.readable) }
}
