// SPDX-License-Identifier: BSD-3-Clause

/// Writes a message to a channel; its handles move with it.
func send<E: IPCErrorCode>(_ message: IPCMessage, on channel: borrowing Handle, _: E.Type) throws(IPCError<E>) {
  try ipcTransport(E.self) { () throws(Status) in
    try Channel.write(channel, bytes: message.bytes, handles: message.handles)
  }
}

/// Waits for the next message on a channel, until `deadline`.
func receive<E: IPCErrorCode>(on channel: borrowing Handle, deadline: Int64, _: E.Type) throws(IPCError<E>)
  -> IPCMessage
{
  try ipcTransport(E.self) { () throws(Status) in
    while true {
      do throws(Status) {
        let m = try Channel.read(channel)
        return IPCMessage(bytes: m.bytes, handles: m.handles)
      } catch .shouldWait {
        _ = try wait(channel, for: Signals.readable | Signals.peerClosed, deadline: deadline)
      }
    }
  }
}

/// The error an error reply carries: the method's own (positive codes) or
/// the framework's (negative codes, transport status values).
func errorReply<E: IPCErrorCode>(_ reply: IPCMessage, _: E.Type) -> IPCError<E> {
  let code: Int32
  do {
    code = try IPCCodec.decode(reply, inlineSize: errorInlineSize, E.self) { (d: inout Decoder) throws(WireError) in
      let code = try d.load(Int32.self, at: 0)
      try d.checkPadding(at: 4, count: 4)
      return code
    }
  } catch {
    return error
  }
  if code > 0, let remote = E(code: code) { return .remote(remote) }
  if code < 0, let status = Status(rawValue: code) { return .transport(status) }
  return .wire(.invalidValue)
}

/// The client's end of a protocol: calls, and the events that arrive
/// meanwhile. Generated `<Name>Client` types wrap one.
public struct IPCClientConnection: ~Copyable {
  public let channel: Handle
  var lastTxid: UInt32 = 0
  var events: [IPCMessage] = []

  public init(channel: consuming Handle) { self.channel = channel }

  /// A fresh transaction id for a call (never 0, which marks one-way).
  public mutating func takeTxid() -> UInt32 {
    lastTxid = lastTxid == UInt32.max ? 1 : lastTxid + 1
    return lastTxid
  }

  /// Sends a one-way request.
  public func send<E: IPCErrorCode>(_ request: IPCMessage, _: E.Type) throws(IPCError<E>) {
    try IPC.send(request, on: channel, E.self)
  }

  /// Sends a call and waits for its reply. Events that arrive first are
  /// queued for `nextEvent`. An error reply is thrown.
  public mutating func call<E: IPCErrorCode>(_ request: IPCMessage, txid: UInt32, _: E.Type)
    throws(IPCError<E>) -> IPCMessage
  {
    try IPC.send(request, on: channel, E.self)
    while true {
      let message = try receive(on: channel, deadline: infiniteDeadline, E.self)
      let header = try ipcWire(E.self) { () throws(WireError) in try message.header() }
      switch header.kind {
      case .reply where header.txid == txid:
        if header.flags & HeaderFlags.error != 0 { throw errorReply(message, E.self) }
        if header.flags & HeaderFlags.canceled != 0 { throw .transport(.canceled) }
        return message
      case .event:
        events.append(message)
      case .epitaph:
        throw .transport(epitaphStatus(message))
      default:
        message.closeHandles()
        throw .wire(.unexpectedMessage)
      }
    }
  }

  /// The next event: a queued one, or the next to arrive before `deadline`.
  public mutating func nextEvent(deadline: Int64) throws(IPCError<Never>) -> (MessageHeader, IPCMessage) {
    while true {
      let message = events.isEmpty
        ? try receive(on: channel, deadline: deadline, Never.self) : events.removeFirst()
      let header = try ipcWire(Never.self) { () throws(WireError) in try message.header() }
      switch header.kind {
      case .event: return (header, message)
      case .epitaph: throw .transport(epitaphStatus(message))
      default:
        message.closeHandles()
        throw .wire(.unexpectedMessage)
      }
    }
  }
}

/// The status an epitaph carries, or `peerClosed` if it is malformed.
func epitaphStatus(_ message: IPCMessage) -> Status {
  guard let status = try? decodeEpitaph(message.bytes.span.bytes) else { return .peerClosed }
  return Status(rawValue: status) ?? .peerClosed
}

/// The server's end of a protocol. Generated `<Name>Server` types wrap one.
public struct IPCServerConnection: ~Copyable {
  public let channel: Handle

  public init(channel: consuming Handle) { self.channel = channel }

  /// The next request, or `nil` once the client has closed its end.
  public func nextRequest() throws(IPCError<Never>) -> (MessageHeader, IPCMessage)? {
    while true {
      let message: IPCMessage
      do throws(IPCError<Never>) {
        message = try receive(on: channel, deadline: infiniteDeadline, Never.self)
      } catch .transport(.peerClosed) {
        return nil
      }
      let header = try ipcWire(Never.self) { () throws(WireError) in try message.header() }
      switch header.kind {
      case .request:
        return (header, message)
      case .cancel:
        // Requests are served one at a time, so a cancelled one has already
        // been answered: nothing more is owed (docs/wire-format.md).
        continue
      default:
        message.closeHandles()
        throw .wire(.unexpectedMessage)
      }
    }
  }

  /// Checks that a request is a call (`twoWay`) or one-way, as its method is.
  public func expect(_ header: MessageHeader, twoWay: Bool, _ message: IPCMessage) throws(IPCError<Never>) {
    guard (header.txid != 0) == twoWay else {
      message.closeHandles()
      throw .wire(.unexpectedMessage)
    }
  }

  /// Sends a message: a reply or an event.
  public func send(_ message: IPCMessage) throws(IPCError<Never>) {
    try IPC.send(message, on: channel, Never.self)
  }

  /// Answers a call with an error code.
  public func replyError(to request: MessageHeader, code: Int32) throws(IPCError<Never>) {
    let reply = try IPCCodec.encode(
      MessageHeader(txid: request.txid, kind: .reply, flags: HeaderFlags.error, ordinal: request.ordinal),
      inlineSize: errorInlineSize, Never.self
    ) { (e: inout Encoder) throws(WireError) in try e.store(code, at: 0) }
    try send(reply)
  }

  /// Answers a request for a method the server doesn't know: an error reply
  /// for a call, nothing for a one-way request.
  public func unknownMethod(_ header: MessageHeader, _ message: IPCMessage) throws(IPCError<Never>) {
    message.closeHandles()
    if header.txid != 0 { try replyError(to: header, code: Status.notSupported.rawValue) }
  }
}
