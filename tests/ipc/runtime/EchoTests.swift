// SPDX-License-Identifier: BSD-3-Clause

import Echo
import IPC
import Testing

@Test func callsRepliesErrorsEventsAndHandles() async throws {
  let ends = try Channel.create()
  let server = startServer(ends.b.release())
  var client = EchoClient(channel: ends.a)

  let said = try client.say("hi", times: 3)
  #expect(said == "hihihi")

  var remote: EchoError?
  do throws(IPCError<EchoError>) {
    _ = try client.say("long", times: 100)
  } catch {
    if case .remote(let e) = error { remote = e }
  }
  #expect(remote == .tooLong)

  try client.note(5, loud: false)
  try client.note(5, loud: true)
  let noted = try client.noted()
  #expect(noted == 15)

  // The event was sent before the first reply, and queued during the call.
  let event = try client.nextEvent()
  guard case .ticked(let n, let label) = event else { Issue.record("wrong event"); return }
  #expect(n == 7 && label == "first")

  let sent = try Event.create()
  let back = try client.swap(sent)
  try signal(back, set: Signals.signaled)
  let observed = try wait(back, for: Signals.signaled, deadline: 0)
  #expect(observed & Signals.signaled != 0)

  _ = consume client  // closing the channel ends the server's loop
  let failure = await server.value
  #expect(failure == nil)
}

@Test func unknownMethodsGetNotSupported() async throws {
  let ends = try Channel.create()
  let server = startServer(ends.b.release())
  var client = EchoClient(channel: ends.a)
  _ = try client.nextEvent()

  let txid = client.connection.takeTxid()
  let request = try IPCCodec.encode(
    MessageHeader(txid: txid, kind: .request, ordinal: 0x1234), inlineSize: 0, Never.self)
  var status: Status?
  do throws(IPCError<Never>) {
    _ = try client.connection.call(request, txid: txid, Never.self)
  } catch {
    if case .transport(let s) = error { status = s }
  }
  #expect(status == .notSupported)
  _ = consume client
  _ = await server.value
}

@Test func ordinalsAreTheWireFormatsHash() {
  // The macro computes ordinals with IPCWire.methodOrdinal; recompute one.
  let name = Array("todhchai.test.Echo.say".utf8)
  #expect(methodOrdinal(name.span) == 0x1458_fe16_9955_bc11)
}
