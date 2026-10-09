// SPDX-License-Identifier: BSD-3-Clause

// M0's exit test (docs/milestones/M0.md): a protocol defined once
// (tests/ipc/echo/Echo.swift) has a Swift client, a C client (from idlc's
// header) and a Swift server, and they exchange messages carrying a handle,
// both ways.

import Echo
import IDLCTests
import IPC
import Testing

@Test func swiftClientAndCClientCallASwiftServer() async throws {
  // The Swift client.
  do {
    let ends = try Channel.create()
    let server = startServer(ends.b.release())
    var client = EchoClient(channel: ends.a)
    let said = try client.say("hi", times: 3)
    #expect(said == "hihihi")

    let event = try Event.create()
    try signal(event, set: 1 << 24)
    let back = try client.swap(event)
    let observed = try wait(back, for: 1 << 24, deadline: 0)  // the same event came back
    #expect(observed & (1 << 24) != 0)

    _ = consume client
    let failure = await server.value
    #expect(failure == nil)
  }

  // The C client, against the same server code.
  do {
    let ends = try Channel.create()
    let server = startServer(ends.b.release())
    let line = idl_c_echo_client(ends.a.release())
    #expect(line == 0, "the C client failed at idl_c_tests.c:\(line)")
    let failure = await server.value
    #expect(failure == nil)
  }
}
