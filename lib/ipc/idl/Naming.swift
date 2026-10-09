// SPDX-License-Identifier: BSD-3-Clause

import IPCModel

/// "noteLoudly" → "note_loudly"; "EchoError" → "echo_error".
func snakeCase(_ name: String) -> String {
  var out = ""
  for (i, c) in name.enumerated() {
    if c.isUppercase {
      if i > 0 { out += "_" }
      out += c.lowercased()
    } else {
      out.append(c)
    }
  }
  return out
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

/// The file name (without extension) idlc gives a protocol's C header.
public func snakeName(_ p: ProtocolModel) -> String { snakeCase(p.name) }
