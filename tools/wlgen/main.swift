// SPDX-License-Identifier: BSD-3-Clause

// wlgen: Wayland protocol XML → Swift (lib/wayland/generated).
//
//   wlgen OUTPUT.swift PROTOCOL.xml...

import FoundationEssentials
import Glibc
import WaylandGen

func fail(_ message: String) -> Never {
  let line = Array("wlgen: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("usage: wlgen OUTPUT.swift PROTOCOL.xml...") }
var protocols: [ProtocolDefinition] = []
for path in args.dropFirst() {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
  do {
    protocols.append(try readProtocol(text))
  } catch {
    fail("\(path): \(error.description)")
  }
}
let source = SwiftGenerator(protocols).generate(sources: args.dropFirst().map { String($0.split(separator: "/").last!) })
do {
  try source.write(toFile: args[0], atomically: true, encoding: .utf8)
} catch {
  fail("can't write \(args[0])")
}
