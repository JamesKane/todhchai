// SPDX-License-Identifier: BSD-3-Clause

// The test protocol: the macro builds it into the Swift tests, and idlc
// reads this file for the C header in tests/ipc/c/generated.

import IPC

enum EchoError: Int32, IPCErrorCode {
  case tooLong = 1
}

@IPCProtocol(id: "todhchai.test.Echo", version: 2)
protocol Echo {
  func say(_ text: String, times: UInt32) throws(EchoError) -> String
  @oneway func note(_ value: UInt64, loud: Bool)
  @event func ticked(_ n: UInt32, label: String)
  func swap(_ handle: consuming Handle) -> Handle
  @since(2) func noted() -> UInt64
}
