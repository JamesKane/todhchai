// SPDX-License-Identifier: BSD-3-Clause

// Enough D-Bus to ask RealtimeKit for a real-time thread, written from the
// D-Bus Specification (freedesktop.org) with no libdbus (principle 29):
// the system bus's socket, SASL EXTERNAL authentication, and method calls
// with the few types RealtimeKit's interface uses. Little-endian
// marshalling throughout ('l').

import Glibc
import TDLinux

/// A D-Bus value this client sends or reads.
enum DBusValue: Equatable {
  case uint32(UInt32)
  case int32(Int32)
  case uint64(UInt64)
  case int64(Int64)
  case string(String)
  case objectPath(String)
  case signature(String)
  indirect case variant(DBusValue)

  var signature: String {
    switch self {
    case .uint32: "u"
    case .int32: "i"
    case .uint64: "t"
    case .int64: "x"
    case .string: "s"
    case .objectPath: "o"
    case .signature: "g"
    case .variant: "v"
    }
  }
}

/// Marshals values, aligning each from the start of the message.
struct DBusWriter {
  var bytes: [UInt8] = []

  mutating func align(_ n: Int) { while bytes.count % n != 0 { bytes.append(0) } }
  mutating func le(_ v: UInt64, _ n: Int) {
    align(n)
    for i in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
  }

  mutating func put(_ v: DBusValue) {
    switch v {
    case .uint32(let x): le(UInt64(x), 4)
    case .int32(let x): le(UInt64(UInt32(bitPattern: x)), 4)
    case .uint64(let x): le(x, 8)
    case .int64(let x): le(UInt64(bitPattern: x), 8)
    case .string(let s), .objectPath(let s):
      let u = Array(s.utf8)
      le(UInt64(u.count), 4)
      bytes += u + [0]
    case .signature(let s):
      let u = Array(s.utf8)
      bytes.append(UInt8(u.count))
      bytes += u + [0]
    case .variant(let inner):
      put(.signature(inner.signature))
      put(inner)
    }
  }
}

/// Reads values back, with the same alignment rules.
struct DBusReader {
  let bytes: [UInt8]
  var at: Int

  mutating func align(_ n: Int) { at = (at + n - 1) / n * n }
  mutating func le(_ n: Int) -> UInt64? {
    align(n)
    guard at + n <= bytes.count else { return nil }
    var v: UInt64 = 0
    for i in 0..<n { v |= UInt64(bytes[at + i]) << (8 * i) }
    at += n
    return v
  }

  mutating func string() -> String? {
    guard let n = le(4).map(Int.init), at + n < bytes.count else { return nil }
    defer { at += n + 1 }
    return String(decoding: bytes[at..<(at + n)], as: UTF8.self)
  }

  mutating func signature() -> String? {
    guard at < bytes.count else { return nil }
    let n = Int(bytes[at])
    guard at + 1 + n < bytes.count else { return nil }
    defer { at += n + 2 }
    return String(decoding: bytes[(at + 1)..<(at + 1 + n)], as: UTF8.self)
  }

  /// One value of a single-type signature.
  mutating func value(_ sig: String) -> DBusValue? {
    switch sig {
    case "u": return le(4).map { .uint32(UInt32($0)) }
    case "i": return le(4).map { .int32(Int32(bitPattern: UInt32($0))) }
    case "t": return le(8).map { .uint64($0) }
    case "x": return le(8).map { .int64(Int64(bitPattern: $0)) }
    case "s": return string().map { .string($0) }
    case "o": return string().map { .objectPath($0) }
    case "g": return signature().map { .signature($0) }
    case "v":
      guard let inner = signature(), let v = value(inner) else { return nil }
      return .variant(v)
    default: return nil
    }
  }
}

/// A reply: its type (2 return, 3 error), the error's name, and its body.
struct DBusReply {
  var isError: Bool
  var errorName: String?
  var body: [DBusValue]
}

enum DBusError: Error, Equatable {
  case connect(Int32)
  case authentication
  case protocolError
  case remote(String)
}

/// A connection to the system bus.
final class DBusConnection {
  let fd: Int32
  var serial: UInt32 = 0

  /// Connects to the system bus and authenticates as this process's user.
  init() throws(DBusError) {
    var path = "/run/dbus/system_bus_socket"
    if let address = getenv("DBUS_SYSTEM_BUS_ADDRESS").map({ String(cString: $0) }),
      address.hasPrefix("unix:path=")
    {
      path = String(address.dropFirst("unix:path=".count).prefix { $0 != "," })
    }
    fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { throw .connect(errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
      for (i, b) in path.utf8.prefix(p.count - 1).enumerated() { p[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else {
      let e = errno
      close(fd)
      throw .connect(e)
    }
    // SASL: a NUL, AUTH EXTERNAL with the uid in hex of its decimal digits.
    let uid = Array(String(getuid()).utf8).map { String($0, radix: 16) }.joined()
    try sendRaw(Array("\0AUTH EXTERNAL \(uid)\r\n".utf8))
    guard let line = try readLine(), line.hasPrefix("OK ") else { throw .authentication }
    try sendRaw(Array("BEGIN\r\n".utf8))
    _ = try call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                 interface: "org.freedesktop.DBus", member: "Hello", [])
  }

  deinit { close(fd) }

  func sendRaw(_ b: [UInt8]) throws(DBusError) {
    var sent = 0
    while sent < b.count {
      let n = b[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
      guard n > 0 else { throw .connect(errno) }
      sent += n
    }
  }

  func readExactly(_ n: Int) throws(DBusError) -> [UInt8] {
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: max(1, n))
    while out.count < n {
      let want = n - out.count
      let got = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, want, 0) }
      guard got > 0 else { throw .connect(got == 0 ? ECONNRESET : errno) }
      out += chunk[..<got]
    }
    return out
  }

  func readLine() throws(DBusError) -> String? {
    var line: [UInt8] = []
    while line.count < 512 {
      let b = try readExactly(1)[0]
      if b == 0x0A { return String(decoding: line.dropLast(line.last == 0x0D ? 1 : 0), as: UTF8.self) }
      line.append(b)
    }
    return nil
  }

  /// Calls a method and waits for its reply (signals on the way are skipped).
  func call(destination: String, path: String, interface: String, member: String, _ args: [DBusValue])
    throws(DBusError) -> [DBusValue]
  {
    serial += 1
    var body = DBusWriter()
    for a in args { body.put(a) }
    let signature = args.map(\.signature).joined()
    var m = DBusWriter()
    m.bytes = [0x6C, 1, 0, 1]  // little-endian, METHOD_CALL, no flags, version 1
    m.le(UInt64(body.bytes.count), 4)
    m.le(UInt64(serial), 4)
    // Header fields: an array of (code, variant).
    var fields = DBusWriter()
    fields.bytes = m.bytes + [0, 0, 0, 0]  // the array's length goes here; alignment counts from the start
    func field(_ code: UInt8, _ v: DBusValue) {
      fields.align(8)
      fields.bytes.append(code)
      fields.put(.variant(v))
    }
    field(1, .objectPath(path))
    field(2, .string(interface))
    field(3, .string(member))
    field(6, .string(destination))
    if !signature.isEmpty { field(8, .signature(signature)) }
    let fieldsLength = fields.bytes.count - 16
    for i in 0..<4 { fields.bytes[12 + i] = UInt8(truncatingIfNeeded: fieldsLength >> (8 * i)) }
    fields.align(8)
    try sendRaw(fields.bytes + body.bytes)
    while true {
      let reply = try readMessage()
      guard let reply else { continue }
      if reply.serial == serial {
        if reply.isError { throw .remote(reply.errorName ?? "error") }
        return reply.body
      }
    }
  }

  /// The next message: a reply to `serial` (with its body), or nil for others.
  func readMessage() throws(DBusError) -> (serial: UInt32, isError: Bool, errorName: String?, body: [DBusValue])? {
    let fixed = try readExactly(16)
    guard fixed[0] == 0x6C else { throw .protocolError }  // the bus answers in our byte order
    func u32(_ at: Int) -> Int { Int(fixed[at]) | Int(fixed[at + 1]) << 8 | Int(fixed[at + 2]) << 16 | Int(fixed[at + 3]) << 24 }
    let type = fixed[1], bodyLength = u32(4), fieldsLength = u32(12)
    let padded = (fieldsLength + 7) / 8 * 8
    let rest = try readExactly(padded + bodyLength)
    var r = DBusReader(bytes: fixed + rest, at: 16)
    var replySerial: UInt32 = 0, errorName: String?, signature = ""
    while r.at < 16 + fieldsLength {
      r.align(8)
      guard r.at < r.bytes.count else { break }
      let code = r.bytes[r.at]
      r.at += 1
      guard case .variant(let v)? = r.value("v") else { throw .protocolError }
      switch (code, v) {
      case (4, .string(let s)): errorName = s
      case (5, .uint32(let s)): replySerial = s
      case (8, .signature(let s)): signature = s
      default: break
      }
    }
    guard type == 2 || type == 3 else { return nil }  // a signal or a call: not ours
    r.at = 16 + padded
    var body: [DBusValue] = []
    for ch in signature {
      guard let v = r.value(String(ch)) else { break }
      body.append(v)
    }
    return (replySerial, type == 3, errorName, body)
  }
}

/// RealtimeKit (org.freedesktop.RealtimeKit1): the desktop's broker for
/// real-time scheduling, for processes without RLIMIT_RTPRIO.
enum RealtimeKit {
  static let name = "org.freedesktop.RealtimeKit1"
  static let path = "/org/freedesktop/RealtimeKit1"

  /// Makes the calling thread SCHED_RR at up to `priority`. RealtimeKit
  /// requires an RLIMIT_RTTIME no larger than its RTTimeUSecMax, so that's
  /// set first (for the whole process). True if it was granted.
  static func makeCurrentThreadRealtime(priority: Int32) -> Bool {
    guard let bus = try? DBusConnection() else { return false }
    func property(_ p: String) -> DBusValue? {
      let r = try? bus.call(destination: name, path: path, interface: "org.freedesktop.DBus.Properties", member: "Get",
                            [.string(name), .string(p)])
      if case .variant(let v)? = r?.first { return v }
      return nil
    }
    var maxPriority = priority
    if case .int32(let m)? = property("MaxRealtimePriority") { maxPriority = min(priority, m) }
    var rttime: Int64 = 200_000
    if case .int64(let t)? = property("RTTimeUSecMax") { rttime = t }
    guard maxPriority > 0, td_linux_set_rttime_limit(UInt64(max(rttime, 1))) == 0 else { return false }
    let tid = td_linux_gettid()
    return (try? bus.call(destination: name, path: path, interface: name, member: "MakeThreadRealtime",
                          [.uint64(tid), .uint32(UInt32(maxPriority))])) != nil
  }
}
