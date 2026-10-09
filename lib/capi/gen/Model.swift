// SPDX-License-Identifier: BSD-3-Clause

// The C ABI as data (sdk.md §12): the types, constants and functions of
// libtodhchai, from which abigen writes the C header and the Zig and Odin
// bindings. The layout of every record is computed here by C's rules, and
// each output asserts it, so the three languages and Swift (which imports
// the C header) can't disagree silently.

public indirect enum CType: Equatable, Sendable {
  case void, bool, u8, u16, u32, u64, i32, i64, f32, f64, usize
  /// A record or alias in the ABI.
  case named(String)
  /// A pointer to an opaque type (`td_loop *`).
  case opaque(String)
  case pointer(CType, const: Bool)
  /// `const char *`, NUL-terminated UTF-8.
  case cString
  case array(CType, Int)
}

public struct Field: Sendable {
  public var name: String
  public var type: CType
  public var doc: String
  public init(_ name: String, _ type: CType, _ doc: String = "") {
    self.name = name
    self.type = type
    self.doc = doc
  }
}

public struct Constant: Sendable {
  public var name: String
  /// The value's bits; negative values are stored as such.
  public var value: Int64
  public var doc: String
  public init(_ name: String, _ value: Int64, _ doc: String = "") {
    self.name = name
    self.value = value
    self.doc = doc
  }
}

public struct Record: Sendable {
  public var name: String
  public var isUnion: Bool
  public var fields: [Field]
  public var doc: String
  /// For a union field of another record: written inline and unnamed in
  /// C (`e->configure`), named in Zig (`e.payload.configure`), `using` in
  /// Odin (`e.configure`).
  public var anonymousInC: Bool
}

public struct Function: Sendable {
  public var name: String
  public var returns: CType
  public var params: [Field]
  public var doc: String
}

public enum Decl: Sendable {
  case section(String)
  case opaque(String, doc: String)
  case alias(String, CType, doc: String)
  case constants(type: CType, [Constant], doc: String)
  case record(Record)
  case function(Function)
}

public struct ABI: Sendable {
  public var prefix: String  // "td_"
  public var decls: [Decl]

  public var records: [Record] {
    decls.compactMap { if case .record(let r) = $0 { r } else { nil } }
  }

  public func record(_ name: String) -> Record? { records.first { $0.name == name } }

  public func alias(_ name: String) -> CType? {
    for d in decls { if case .alias(let n, let t, _) = d, n == name { return t } }
    return nil
  }

  // MARK: Layout, by the x86-64 and AArch64 System V rules

  public func size(_ t: CType) -> Int { layout(t).size }
  public func align(_ t: CType) -> Int { layout(t).align }

  func layout(_ t: CType) -> (size: Int, align: Int) {
    switch t {
    case .void: return (0, 1)
    case .bool, .u8: return (1, 1)
    case .u16: return (2, 2)
    case .u32, .i32, .f32: return (4, 4)
    case .u64, .i64, .f64, .usize, .opaque, .pointer, .cString: return (8, 8)
    case .array(let e, let n):
      let l = layout(e)
      return (l.size * n, l.align)
    case .named(let n):
      if let a = alias(n) { return layout(a) }
      guard let r = record(n) else { fatalError("abigen: no type \(n)") }
      return recordLayout(r)
    }
  }

  public func recordLayout(_ r: Record) -> (size: Int, align: Int) {
    var size = 0, align = 1
    for f in r.fields {
      let l = layout(f.type)
      align = max(align, l.align)
      size = r.isUnion ? max(size, l.size) : roundUp(size, l.align) + l.size
    }
    return (roundUp(size, align), align)
  }

  /// Each field's offset. An anonymous union's members are reported at
  /// the union's offset too, by their own names.
  public func offsets(_ r: Record) -> [(name: String, offset: Int)] {
    var out: [(String, Int)] = []
    var at = 0
    for f in r.fields {
      let l = layout(f.type)
      let offset = r.isUnion ? 0 : roundUp(at, l.align)
      out.append((f.name, offset))
      at = offset + l.size
    }
    return out
  }
}

func roundUp(_ n: Int, _ a: Int) -> Int { (n + a - 1) / a * a }

// MARK: Names

extension ABI {
  /// `td_cpu_surface` → `cpu_surface`; `TD_EV_FRAME` → `EV_FRAME`.
  public func bare(_ name: String) -> String {
    if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
    if name.hasPrefix(prefix.uppercased()) { return String(name.dropFirst(prefix.count)) }
    return name
  }
}

/// `cpu_surface` → ["cpu", "surface"].
func words(_ snake: String) -> [String] { snake.split(separator: "_").map(String.init) }

/// `leftBracket` → `LEFT_BRACKET`, `nonUSHash` → `NON_US_HASH`, `f1` → `F1`.
public func upperSnake(_ camel: String) -> String {
  var out = ""
  let cs = Array(camel)
  for (i, ch) in cs.enumerated() {
    if i > 0, ch.isUppercase {
      let prev = cs[i - 1]
      let nextLower = i + 1 < cs.count && cs[i + 1].isLowercase
      if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextLower) { out += "_" }
    }
    out += ch.uppercased()
  }
  return out
}
