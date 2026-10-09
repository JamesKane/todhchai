// SPDX-License-Identifier: BSD-3-Clause

// SPA POD, PipeWire's message encoding (docs/research/pipewire-protocol.md
// §2): an 8-byte header (body size without padding, type), the body, then
// zero padding to 8. Containers count their children's padded sizes.

/// POD type ids.
public enum PodType: UInt32, Sendable {
  // `.null` is None: named so it can't be confused with Optional's .none.
  case null = 1, bool, id, int, long, float, double, string, bytes, rectangle, fraction, bitmap
  case array, `struct`, object, sequence, pointer, fd, choice, pod
}

/// A decoded POD.
public indirect enum Pod: Sendable, Equatable {
  case none
  case bool(Bool)
  case id(UInt32)
  case int(Int32)
  case long(Int64)
  case float(Float)
  case double(Double)
  case string(String)
  case bytes([UInt8])
  case fraction(UInt32, UInt32)
  case rectangle(UInt32, UInt32)
  case array(childType: UInt32, [Pod])
  case `struct`([Pod])
  case object(type: UInt32, id: UInt32, [Property])
  case choice(type: UInt32, [Pod])
  case fd(Int64)
  /// A type this client doesn't decode (kept so parsing can continue).
  case other(type: UInt32)

  public struct Property: Sendable, Equatable {
    public var key: UInt32
    public var flags: UInt32
    public var value: Pod
    public init(_ key: UInt32, _ value: Pod, flags: UInt32 = 0) {
      self.key = key
      self.flags = flags
      self.value = value
    }
  }

  // Convenience accessors for parsing messages.
  public var int: Int32? { if case .int(let v) = self { v } else { nil } }
  public var long: Int64? { if case .long(let v) = self { v } else { nil } }
  public var idValue: UInt32? { if case .id(let v) = self { v } else { nil } }
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  public var fd: Int64? { if case .fd(let v) = self { v } else { nil } }
  public var fields: [Pod]? { if case .struct(let v) = self { v } else { nil } }
}

public enum PodError: Error, Equatable {
  case truncated
  case malformed(String)
}

// MARK: Encoding

/// Writes PODs.
public struct PodWriter {
  public private(set) var bytes: [UInt8] = []

  public init() {}

  mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
  mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
  mutating func pad() { while bytes.count % 8 != 0 { bytes.append(0) } }

  /// Appends one POD, padded.
  public mutating func write(_ pod: Pod) {
    switch pod {
    case .none: header(0, .null)
    case .bool(let v): header(4, .bool); u32(v ? 1 : 0); pad()
    case .id(let v): header(4, .id); u32(v); pad()
    case .int(let v): header(4, .int); u32(UInt32(bitPattern: v)); pad()
    case .long(let v): header(8, .long); u64(UInt64(bitPattern: v))
    case .float(let v): header(4, .float); u32(v.bitPattern); pad()
    case .double(let v): header(8, .double); u64(v.bitPattern)
    case .string(let s):
      let b = Array(s.utf8) + [0]
      header(UInt32(b.count), .string); bytes += b; pad()
    case .bytes(let b): header(UInt32(b.count), .bytes); bytes += b; pad()
    case .fraction(let n, let d): header(8, .fraction); u32(n); u32(d)
    case .rectangle(let w, let h): header(8, .rectangle); u32(w); u32(h)
    case .fd(let v): header(8, .fd); u64(UInt64(bitPattern: v))
    case .array(let childType, let children):
      container(.array) { w in
        let size = Self.childBodySize(childType)
        w.u32(size)
        w.u32(childType)
        for c in children { w.body(c) }
      }
    case .struct(let children):
      container(.struct) { w in for c in children { w.write(c) } }
    case .object(let type, let id, let properties):
      container(.object) { w in
        w.u32(type)
        w.u32(id)
        for p in properties {
          w.u32(p.key)
          w.u32(p.flags)
          w.write(p.value)
        }
      }
    case .choice(let type, let values):
      container(.choice) { w in
        w.u32(type)
        w.u32(0)
        let childType = values.first.map(Self.typeOf) ?? PodType.null.rawValue
        w.u32(Self.childBodySize(childType))
        w.u32(childType)
        for v in values { w.body(v) }
      }
    case .other: header(0, .null)
    }
  }

  mutating func header(_ size: UInt32, _ type: PodType) {
    u32(size)
    u32(type.rawValue)
  }

  /// A container: its size is everything written inside, padding included,
  /// except its own trailing padding.
  mutating func container(_ type: PodType, _ body: (inout PodWriter) -> Void) {
    let at = bytes.count
    header(0, type)
    var inner = PodWriter()
    body(&inner)
    bytes += inner.bytes
    let size = UInt32(inner.bytes.count)
    withUnsafeBytes(of: size.littleEndian) { for (i, b) in $0.enumerated() { bytes[at + i] = b } }
    pad()
  }

  /// A value's body alone (array and choice children have no headers).
  mutating func body(_ pod: Pod) {
    switch pod {
    case .bool(let v): u32(v ? 1 : 0)
    case .id(let v): u32(v)
    case .int(let v): u32(UInt32(bitPattern: v))
    case .long(let v): u64(UInt64(bitPattern: v))
    case .float(let v): u32(v.bitPattern)
    case .double(let v): u64(v.bitPattern)
    case .fraction(let n, let d): u32(n); u32(d)
    case .rectangle(let w, let h): u32(w); u32(h)
    default: break
    }
  }

  static func typeOf(_ pod: Pod) -> UInt32 {
    switch pod {
    case .bool: PodType.bool.rawValue
    case .id: PodType.id.rawValue
    case .int: PodType.int.rawValue
    case .long: PodType.long.rawValue
    case .float: PodType.float.rawValue
    case .double: PodType.double.rawValue
    case .fraction: PodType.fraction.rawValue
    case .rectangle: PodType.rectangle.rawValue
    default: PodType.null.rawValue
    }
  }

  static func childBodySize(_ type: UInt32) -> UInt32 {
    switch PodType(rawValue: type) {
    case .bool, .id, .int, .float: 4
    case .long, .double, .fraction, .rectangle: 8
    default: 0
    }
  }
}

// MARK: Decoding

/// Reads one POD at `offset` in `b`; returns it and the offset after it
/// (padding included).
public func readPod(_ b: ArraySlice<UInt8>, at offset: Int) throws(PodError) -> (Pod, Int) {
  func u32(_ o: Int) throws(PodError) -> UInt32 {
    guard o + 4 <= b.endIndex else { throw .truncated }
    return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
  }
  func u64(_ o: Int) throws(PodError) -> UInt64 { UInt64(try u32(o)) | UInt64(try u32(o + 4)) << 32 }
  let size = Int(try u32(offset)), type = try u32(offset + 4)
  let body = offset + 8
  guard body + size <= b.endIndex else { throw .truncated }
  let next = body + (size + 7) & ~7
  func value(_ type: UInt32, _ o: Int, _ size: Int) throws(PodError) -> Pod {
    switch PodType(rawValue: type) {
    case .null: return .none
    case .bool: return .bool(try u32(o) != 0)
    case .id: return .id(try u32(o))
    case .int: return .int(Int32(bitPattern: try u32(o)))
    case .long: return .long(Int64(bitPattern: try u64(o)))
    case .float: return .float(Float(bitPattern: try u32(o)))
    case .double: return .double(Double(bitPattern: try u64(o)))
    case .fraction: return .fraction(try u32(o), try u32(o + 4))
    case .rectangle: return .rectangle(try u32(o), try u32(o + 4))
    case .fd: return .fd(Int64(bitPattern: try u64(o)))
    case .string:
      let raw = b[o..<(o + size)]
      return .string(String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self))
    case .bytes: return .bytes(Array(b[o..<(o + size)]))
    default: return .other(type: type)
    }
  }
  switch PodType(rawValue: type) {
  case .struct:
    var children: [Pod] = []
    var at = body
    while at < body + size {
      let (child, after) = try readPod(b, at: at)
      children.append(child)
      at = after
    }
    return (.struct(children), next)
  case .object:
    let objectType = try u32(body), objectID = try u32(body + 4)
    var properties: [Pod.Property] = []
    var at = body + 8
    while at < body + size {
      let key = try u32(at), flags = try u32(at + 4)
      let (v, after) = try readPod(b, at: at + 8)
      properties.append(Pod.Property(key, v, flags: flags))
      at = after
    }
    return (.object(type: objectType, id: objectID, properties), next)
  case .array:
    let childSize = Int(try u32(body)), childType = try u32(body + 4)
    var children: [Pod] = []
    if childSize > 0 {
      var at = body + 8
      while at + childSize <= body + size {
        children.append(try value(childType, at, childSize))
        at += childSize
      }
    }
    return (.array(childType: childType, children), next)
  case .choice:
    let choiceType = try u32(body)
    let childSize = Int(try u32(body + 8)), childType = try u32(body + 12)
    var values: [Pod] = []
    if childSize > 0 {
      var at = body + 16
      while at + childSize <= body + size {
        values.append(try value(childType, at, childSize))
        at += childSize
      }
    }
    return (.choice(type: choiceType, values), next)
  default:
    return (try value(type, body, size), next)
  }
}

/// A property dictionary as PipeWire writes it: Int count, then string pairs.
public func dictionaryPods(_ items: [(String, String)]) -> [Pod] {
  [.int(Int32(items.count))] + items.flatMap { [Pod.string($0.0), .string($0.1)] }
}

/// Reads a dictionary from `fields` starting at `index`; returns it and the
/// index after it.
public func readDictionary(_ fields: [Pod], at index: Int) -> ([String: String], Int) {
  guard index < fields.count, let n = fields[index].int, n >= 0 else { return ([:], index + 1) }
  var out: [String: String] = [:]
  var i = index + 1
  for _ in 0..<Int(n) where i + 1 < fields.count {
    if let k = fields[i].string, let v = fields[i + 1].string { out[k] = v }
    i += 2
  }
  return (out, i)
}
