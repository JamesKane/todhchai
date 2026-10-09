// SPDX-License-Identifier: BSD-3-Clause

// AML for tests, built from its grammar (ACPI 6.5 §20.2): what an ASL
// compiler would emit, so the synthetic tests need neither a compiler nor
// third-party tables.

enum AML {
  /// PkgLength (§20.2.4) for `content` bytes: the length counts its own
  /// bytes. One byte below 64; else a lead byte (how many follow, in bits
  /// 7-6, and the low nibble) and up to three more.
  static func pkgLength(_ content: Int) -> [UInt8] {
    if content + 1 < 0x40 { return [UInt8(content + 1)] }
    for n in 2...4 {
      let total = content + n
      guard total < 1 << (4 + 8 * (n - 1)) else { continue }
      var out = [UInt8((n - 1) << 6 | (total & 0x0F))]
      for k in 0..<(n - 1) { out.append(UInt8(truncatingIfNeeded: total >> (4 + 8 * k))) }
      return out
    }
    fatalError("a package over 256 MiB")
  }

  /// A package: PkgLength, then its bytes.
  static func package(_ content: [UInt8]) -> [UInt8] { pkgLength(content.count) + content }

  /// A NameSeg (§20.2.2): four characters, padded with "_".
  static func seg(_ s: Substring) -> [UInt8] {
    let b = Array(s.utf8)
    precondition(b.count >= 1 && b.count <= 4, "a name segment is 1 to 4 characters: \(s)")
    return b + [UInt8](repeating: 0x5F, count: 4 - b.count)
  }

  /// A NameString: "\" for the root, "^" for each parent, then segments
  /// joined by "." (one plain; two DualNamePrefix; more MultiNamePrefix;
  /// none NullName).
  static func name(_ path: String) -> [UInt8] {
    var rest = Substring(path)
    var out: [UInt8] = []
    if rest.first == "\\" {
      out.append(0x5C)
      rest = rest.dropFirst()
    }
    while rest.first == "^" {
      out.append(0x5E)
      rest = rest.dropFirst()
    }
    let segments = rest.isEmpty ? [] : rest.split(separator: ".", omittingEmptySubsequences: false)
    switch segments.count {
    case 0: out.append(0x00)
    case 1: out += seg(segments[0])
    case 2: out += [0x2E] + seg(segments[0]) + seg(segments[1])
    default:
      out += [0x2F, UInt8(segments.count)]
      for s in segments { out += seg(s) }
    }
    return out
  }

  /// An integer in the shortest form (§20.2.3): Zero, One, Ones, then
  /// byte, word, dword or qword.
  static func integer(_ v: UInt64) -> [UInt8] {
    switch v {
    case 0: [0x00]
    case 1: [0x01]
    case UInt64.max: [0xFF]
    case ..<0x100: [0x0A, UInt8(v)]
    case ..<0x1_0000: [0x0B] + le(v, 2)
    case ..<0x1_0000_0000: [0x0C] + le(v, 4)
    default: [0x0E] + le(v, 8)
    }
  }

  static func string(_ s: String) -> [UInt8] { [0x0D] + Array(s.utf8) + [0] }

  static func buffer(_ bytes: [UInt8]) -> [UInt8] { [0x11] + package(integer(UInt64(bytes.count)) + bytes) }

  static func packageOf(_ elements: [[UInt8]]) -> [UInt8] {
    [0x12] + package([UInt8(elements.count)] + elements.flatMap { $0 })
  }

  static func scope(_ path: String, _ body: [UInt8]) -> [UInt8] { [0x10] + package(name(path) + body) }

  static func device(_ path: String, _ body: [UInt8]) -> [UInt8] { [0x5B, 0x82] + package(name(path) + body) }

  static func nameObject(_ path: String, _ value: [UInt8]) -> [UInt8] { [0x08] + name(path) + value }

  /// A method: argument count (0-7), serialized, sync level (0-15).
  static func method(_ path: String, args: Int = 0, serialized: Bool = false, syncLevel: Int = 0, _ body: [UInt8])
    -> [UInt8]
  {
    let flags = UInt8(args) | (serialized ? 0x08 : 0) | UInt8(syncLevel << 4)
    return [0x14] + package(name(path) + [flags] + body)
  }

  static func returning(_ value: [UInt8]) -> [UInt8] { [0xA4] + value }

  /// A DSDT whose AML is `body`.
  static func dsdt(_ body: [UInt8], revision: UInt8 = 2) -> [UInt8] { table("DSDT", revision: revision, body) }
}
