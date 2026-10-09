// SPDX-License-Identifier: BSD-3-Clause

// The test protocol, and a server for it. The macro builds it into the
// Swift tests; idlc reads this file for the C header in tests/ipc/c/generated.

import IPC

public enum EchoError: Int32, IPCErrorCode {
  case tooLong = 1
}

@IPCProtocol(id: "todhchai.test.Echo", version: 2)
public protocol Echo {
  func say(_ text: String, times: UInt32) throws(EchoError) -> String
  @oneway func note(_ value: UInt64, loud: Bool)
  @event func ticked(_ n: UInt32, label: String)
  func swap(_ handle: consuming Handle) -> Handle
  @since(2) func noted() -> UInt64
}

public struct EchoImpl: EchoHandler {
  var notes: UInt64 = 0

  public init() {}

  public mutating func say(_ text: String, times: UInt32) throws(EchoError) -> String {
    guard text.utf8.count * Int(times) <= 64 else { throw .tooLong }
    return String(repeating: text, count: Int(times))
  }

  public mutating func note(_ value: UInt64, loud: Bool) { notes += loud ? value * 2 : value }

  public mutating func swap(_ handle: consuming Handle) -> Handle { handle }

  public mutating func noted() -> UInt64 { notes }
}

/// Starts a server on its own thread; it sends one event, then serves.
public func startServer(_ raw: UInt32) -> Task<IPCError<Never>?, Never> {
  Task.detached {
    var server = EchoServer(channel: Handle(raw: raw), impl: EchoImpl())
    do throws(IPCError<Never>) {
      try server.sendTicked(7, label: "first")
      try server.serve()
      return nil
    } catch {
      return error
    }
  }
}
