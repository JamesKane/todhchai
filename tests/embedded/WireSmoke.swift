// SPDX-License-Identifier: BSD-3-Clause

// Runs IPCWire built as Embedded Swift on the host: the golden request from
// tests/ipc/wire/WireTests.swift, encoded and decoded. The first failed
// check traps, and ctest reports the test as failed.

import IPCWire

let golden: [UInt8] = [
  0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00,
  0x11, 0xbc, 0x55, 0x99, 0x16, 0xfe, 0x58, 0x14,
  0x07, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
  0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
  0x68, 0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]

@main struct WireSmoke {
  static func main() {
    do throws(WireError) {
      try encode()
      try decode()
    } catch {
      fatalError("wire error")
    }
    print("embedded IPCWire: ok")
  }

  static func encode() throws(WireError) {
    var buffer = [UInt8](repeating: 0xee, count: 64)
    var handles: [UInt32] = [0, 0]
    let name: [UInt8] = Array("todhchai.test.Echo.say".utf8)
    let hi: [UInt8] = [0x68, 0x69]
    var bytes = buffer.mutableSpan
    var e = Encoder(bytes: bytes.mutableBytes, handles: handles.mutableSpan)
    try e.header(MessageHeader(txid: 1, kind: .request, ordinal: methodOrdinal(name.span)))
    try e.beginBody(inlineSize: 24)
    try e.store(UInt32(7), at: 0)
    try e.storeHandle(0xabcd, at: 4)
    try e.storeBytes(hi.span.bytes, at: 8)
    let (byteCount, handleCount) = e.finish()
    check(byteCount == golden.count && handleCount == 1 && handles[0] == 0xabcd, "encoded sizes")
    for i in 0..<byteCount { check(buffer[i] == golden[i], "encoded bytes") }
  }

  static func decode() throws(WireError) {
    let handles: [UInt32] = [0xabcd]
    var d = try Decoder(bytes: golden.span.bytes, handles: handles.span)
    try d.beginBody(inlineSize: 24)
    check(try d.load(UInt32.self, at: 0) == 7, "decoded value")
    check(try d.loadHandle(at: 4) == 0xabcd, "decoded handle")
    let s = try d.loadBytes(at: 8)
    check(s.byteCount == 2 && s.load(fromByteOffset: 1, as: UInt8.self) == 0x69, "decoded string")
    try d.finish()
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
