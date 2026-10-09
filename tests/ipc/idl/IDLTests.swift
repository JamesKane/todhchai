// SPDX-License-Identifier: BSD-3-Clause

import FoundationEssentials
import IDL
import IDLCTests
import IPC
import IPCModel
import Testing

// MARK: Generated files stay in step with idlc

/// The repository's root, from this file's path.
let root: String = {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(4)  // tests/ipc/idl/IDLTests.swift
  return parts.joined(separator: "/")
}()

func read(_ path: String) throws -> String { try String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) }

func echoInterface() throws -> Interface {
  let path = "tests/ipc/echo/Echo.swift"
  return try scan([(path, try read(path))])
}

@Test func checkedInOutputsMatchIdlc() throws {
  let interface = try echoInterface()
  let echo = try #require(interface.protocols.first)
  let source = "tests/ipc/echo/Echo.swift"
  #expect(cHeader(echo, errors: interface.errors, source: source) == (try read("tests/ipc/c/generated/echo.h")),
          "regenerate: swift run idlc --c-out tests/ipc/c/generated \(source)")
  #expect(markdown(echo, errors: interface.errors, source: source) == (try read("tests/ipc/docs/Echo.md")))
  #expect(Baseline(echo).text == (try read("tests/ipc/baselines/todhchai.test.Echo.api")))
  #expect(interface.errors["EchoError"]?.cases.first?.code == 1)
}

// MARK: C and Swift agree on the bytes

@Test func cEncodesWhatSwiftEncodes() throws {
  var c = [UInt8](repeating: 0, count: 256)
  let n = idl_c_encode_say(&c, UInt32(c.count))
  let say = try #require(try echoInterface().protocols.first?.methods.first { $0.name == "say" })
  let swift = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .request, ordinal: say.ordinal), inlineSize: say.request.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in
    try e.storeString("hi", at: 0)
    try e.store(UInt32(3), at: 16)
  }
  #expect(Array(c[..<Int(n)]) == swift.bytes)
}

@Test func cDecodesWhatSwiftEncodes() throws {
  let say = try #require(try echoInterface().protocols.first?.methods.first { $0.name == "say" })
  let reply = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .reply, ordinal: say.ordinal), inlineSize: say.reply.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in try e.storeString("hihihi", at: 0) }
  var text = [CChar](repeating: 0, count: 64)
  #expect(idl_c_decode_say_reply(reply.bytes, UInt32(reply.bytes.count), &text, 64) == 0)
  #expect(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "hihihi")

  // Hostile replies: padding, an overlong string count, invalid UTF-8.
  for (offset, value) in [(16 + 16 + 6, UInt8(1)), (16, 0x40), (16 + 16, 0xff)] {
    var bad = reply.bytes
    bad[offset] = value
    #expect(idl_c_decode_say_reply(bad, UInt32(bad.count), &text, 64) != 0, "byte \(offset) = \(value)")
  }
}

@Test func cUTF8ValidationMatchesSwift() {
  let cases: [[UInt8]] = [
    [], [0x41], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80], [0xc2, 0x80], [0xf4, 0x8f, 0xbf, 0xbf],
    [0xc0, 0x80], [0xc1, 0xbf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
    [0xf5, 0x80, 0x80, 0x80], [0xe2, 0x82], [0x80], [0xff], [0xef, 0xbf, 0xbf], [0xee, 0x80, 0x80],
  ]
  for bytes in cases {
    let swift = String(validating: bytes, as: UTF8.self) != nil
    #expect((idl_c_utf8_valid(bytes, UInt32(bytes.count)) != 0) == swift, "\(bytes)")
  }
}

// MARK: Evolution

func baseline(_ body: String, version: Int) throws -> Baseline {
  let source = "@IPCProtocol(id: \"t.P\", version: \(version))\nprotocol P {\n\(body)\n}"
  let p = try #require(try scan([("P.swift", source)]).protocols.first)
  return Baseline(p)
}

@Test func compatibleChangesPass() throws {
  let old = try baseline("func a(_ x: UInt32) -> String", version: 1)
  let added = try baseline("func a(_ x: UInt32) -> String\n@since(2) func b()", version: 2)
  #expect(compatibility(old: old, new: added).isEmpty)
  let renamedParameter = try baseline("func a(_ y: UInt32) -> String", version: 1)
  #expect(compatibility(old: old, new: renamedParameter).isEmpty)
  #expect(Baseline(text: old.text) == old)
}

@Test func breakingChangesFail() throws {
  let old = try baseline("func a(_ x: UInt32) -> String\nfunc c()", version: 1)
  let cases: [(String, Int, String)] = [
    ("func a(_ x: UInt64) -> String\nfunc c()", 1, "'a' changed"),
    ("func a(_ x: UInt32)\nfunc c()", 1, "'a' changed"),
    ("@oneway func a(_ x: UInt32)\nfunc c()", 1, "'a' changed"),
    ("func a(_ x: UInt32) -> String", 1, "'c' was removed"),
    ("func a(_ x: UInt32) -> String\nfunc c()\nfunc b()", 2, "'b' is new, so it needs @since(2)"),
    ("func a(_ x: UInt32) -> String\nfunc c()\n@since(1) func b()", 1, "the version must go up"),
  ]
  for (body, version, expected) in cases {
    let problems = compatibility(old: old, new: try baseline(body, version: version))
    #expect(problems.contains { $0.contains(expected) }, "\(body): \(problems)")
  }
  let older = try baseline("func a(_ x: UInt32) -> String\nfunc c()", version: 1)
  var lowered = older
  lowered.version = 0
  #expect(compatibility(old: older, new: lowered).contains { $0.contains("went down") })
}
