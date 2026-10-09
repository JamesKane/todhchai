// SPDX-License-Identifier: BSD-3-Clause

// The Wayland wire format, from the Wayland documentation ("Wire Format"):
// a message is the object id (32 bits), then the size in bytes (high 16
// bits) and opcode (low 16 bits), then the arguments, each a multiple of 4
// bytes, in the host's byte order. File descriptors travel separately, as
// SCM_RIGHTS ancillary data on the socket.

/// Every generated interface type.
public protocol WaylandObject: Hashable, Sendable {
  var id: UInt32 { get }
  init(id: UInt32)
  static var interface: WaylandInterface { get }
}

/// A 24.8 signed fixed-point number.
public struct WaylandFixed: Hashable, Sendable {
  public var raw: Int32
  public init(raw: Int32) { self.raw = raw }
  public init(_ value: Double) { raw = Int32((value * 256).rounded()) }
  public var double: Double { Double(raw) / 256 }
}

public enum WaylandError: Error, Equatable {
  /// A message ended before its arguments did.
  case truncated
  /// A string without its terminating NUL, or not UTF-8.
  case badString
  /// A message said it carried a file descriptor that didn't arrive.
  case missingFD
  /// An event for an object this connection doesn't know.
  case unknownObject(UInt32)
  /// An opcode the interface doesn't have.
  case unknownOpcode(String, UInt16)
  /// A required object or string was null.
  case unexpectedNull
  /// The compositor reported a fatal protocol error and will disconnect.
  case protocolError(object: UInt32, code: UInt32, message: String)
  /// No compositor to connect to ($WAYLAND_DISPLAY unset, or no socket).
  case noDisplay
  /// The socket failed (errno).
  case system(Int32)
  /// The compositor closed the connection.
  case closed
}

/// A request being encoded.
public struct WaylandMessage {
  var words: [UInt32] = []
  var fds: [Int32] = []

  public init() {}

  public mutating func int(_ v: Int32) { words.append(UInt32(bitPattern: v)) }
  public mutating func uint(_ v: UInt32) { words.append(v) }
  public mutating func fixed(_ v: WaylandFixed) { words.append(UInt32(bitPattern: v.raw)) }
  public mutating func fd(_ fd: Int32) { fds.append(fd) }

  /// A string: its length with the NUL, the bytes, the NUL, padding to 4.
  /// A null string is a length of 0.
  public mutating func string(_ s: String?) {
    guard let s else { return words.append(0) }
    bytes(Array(s.utf8) + [0])
  }

  public mutating func array(_ a: [UInt8]) { bytes(a) }

  mutating func bytes(_ b: [UInt8]) {
    words.append(UInt32(b.count))
    var padded = b
    while padded.count % 4 != 0 { padded.append(0) }
    for i in stride(from: 0, to: padded.count, by: 4) {
      words.append(UInt32(padded[i]) | UInt32(padded[i + 1]) << 8 | UInt32(padded[i + 2]) << 16 | UInt32(padded[i + 3]) << 24)
    }
  }
}

/// An event's arguments being decoded.
public struct WaylandReader {
  let words: ArraySlice<UInt32>
  var next: Int
  let connection: WaylandConnection

  init(_ words: ArraySlice<UInt32>, _ connection: WaylandConnection) {
    self.words = words
    self.next = words.startIndex
    self.connection = connection
  }

  public mutating func uint() throws(WaylandError) -> UInt32 {
    guard next < words.endIndex else { throw .truncated }
    defer { next += 1 }
    return words[next]
  }

  public mutating func int() throws(WaylandError) -> Int32 { Int32(bitPattern: try uint()) }
  public mutating func fixed() throws(WaylandError) -> WaylandFixed { WaylandFixed(raw: try int()) }

  public mutating func array() throws(WaylandError) -> [UInt8] {
    let count = Int(try uint())
    let wordCount = (count + 3) / 4
    guard next + wordCount <= words.endIndex else { throw .truncated }
    var out: [UInt8] = []
    out.reserveCapacity(count)
    for w in words[next..<(next + wordCount)] {
      for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> (8 * k))) }
    }
    next += wordCount
    return Array(out.prefix(count))
  }

  public mutating func string() throws(WaylandError) -> String? {
    let bytes = try array()
    if bytes.isEmpty { return nil }
    guard bytes.last == 0, let s = String(validating: bytes.dropLast(), as: UTF8.self) else { throw .badString }
    return s
  }

  public mutating func requiredString() throws(WaylandError) -> String {
    guard let s = try string() else { throw .unexpectedNull }
    return s
  }

  public mutating func object<T: WaylandObject>(_: T.Type) throws(WaylandError) -> T? {
    let id = try uint()
    return id == 0 ? nil : T(id: id)
  }

  public mutating func requiredObject<T: WaylandObject>(_: T.Type) throws(WaylandError) -> T {
    guard let o = try object(T.self) else { throw .unexpectedNull }
    return o
  }

  /// An object the compositor made: from now on its events decode as T's.
  public mutating func newObject<T: WaylandObject>(_: T.Type, _ c: WaylandConnection, version: UInt32)
    throws(WaylandError) -> T
  {
    let id = try uint()
    c.register(id, T.interface, version: version)
    return T(id: id)
  }

  public mutating func newObject(_: UInt32.Type, _ c: WaylandConnection, version: UInt32) throws(WaylandError) -> UInt32 {
    try uint()
  }

  /// The next file descriptor that arrived; the caller owns it.
  public mutating func fd() throws(WaylandError) -> Int32 {
    guard !connection.receivedFDs.isEmpty else { throw .missingFD }
    return connection.receivedFDs.removeFirst()
  }
}
