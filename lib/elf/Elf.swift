// SPDX-License-Identifier: BSD-3-Clause

// ELF64 executables, as a loader needs them (System V ABI, "ELF-64 Object
// File Format" 1.5, and the gABI's program headers): the entry point, the
// PT_LOAD segments and the stack PT_GNU_STACK asks for. Little-endian only,
// as croi's three architectures are. Tier 0: the native launcher loads
// programs from bootfs with it (lib/sys/backend/native).
//
// A loader has the file's start, not all of it: `ElfImage(header:)` reads
// the header and the program headers from the bytes it is given, and asks
// for more (`needs`) if the program headers lie past them.

public struct ElfImage: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// ET_EXEC: loaded at the addresses it names.
    case executable
    /// ET_DYN: position-independent (not loaded yet).
    case shared
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    /// Not ELF64, little-endian, version 1, executable or shared.
    case notElf
    /// For another machine than the one asked for.
    case wrongMachine(UInt16)
    /// The program headers end at this offset: read that much and ask again.
    case needs(Int)
    /// A program header that makes no sense (its index).
    case badSegment(Int)
  }

  public struct Segment: Equatable, Sendable {
    /// In the file.
    public var offset: UInt64
    public var vaddr: UInt64
    public var filesz: UInt64
    public var memsz: UInt64
    public var readable: Bool
    public var writable: Bool
    public var executable: Bool
  }

  /// e_machine values.
  public enum Machine {
    public static let amd64: UInt16 = 62
    public static let arm64: UInt16 = 183
    public static let rv64: UInt16 = 243
  }

  public static let headerSize = 64
  static let programHeaderSize = 56
  static let ptLoad: UInt32 = 1
  static let ptGnuStack: UInt32 = 0x6474_E551

  public var kind: Kind
  public var machine: UInt16
  public var entry: UInt64
  /// PT_LOAD, in the file's order.
  public var segments: [Segment] = []
  /// PT_GNU_STACK's size, if it gives one.
  public var stackSize: UInt64?

  /// Reads `header`, the file's first bytes, which is `fileSize` long. With
  /// `machine`, refuses another machine's program.
  public init(header: [UInt8], fileSize: Int, machine wanted: UInt16? = nil) throws(Error) {
    func u16(_ at: Int) -> UInt16 { UInt16(header[at]) | UInt16(header[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }

    // e_ident: magic, ELFCLASS64, ELFDATA2LSB, EV_CURRENT.
    guard header.count >= Self.headerSize, header[0] == 0x7F, header[1] == UInt8(ascii: "E"),
      header[2] == UInt8(ascii: "L"), header[3] == UInt8(ascii: "F"), header[4] == 2, header[5] == 1, header[6] == 1,
      u32(20) == 1
    else { throw .notElf }
    switch u16(16) {
    case 2: kind = .executable
    case 3: kind = .shared
    default: throw .notElf
    }
    machine = u16(18)
    if let wanted, machine != wanted { throw .wrongMachine(machine) }
    entry = u64(24)
    let phoff = u64(32)
    let phentsize = Int(u16(54)), phnum = Int(u16(56))
    guard phnum == 0 || phentsize >= Self.programHeaderSize, phoff <= UInt64(fileSize) else { throw .notElf }
    let end = Int(phoff) + phentsize * phnum
    guard end <= fileSize else { throw .notElf }
    guard end <= header.count else { throw .needs(end) }

    for i in 0..<phnum {
      let at = Int(phoff) + phentsize * i
      switch u32(at) {
      case Self.ptLoad:
        let flags = u32(at + 4)
        let s = Segment(offset: u64(at + 8), vaddr: u64(at + 16), filesz: u64(at + 32), memsz: u64(at + 40),
                        readable: flags & 4 != 0, writable: flags & 2 != 0, executable: flags & 1 != 0)
        let align = u64(at + 48)
        // In the file, no larger in it than in memory, congruent with its
        // address modulo the page (so it can be mapped), and not wrapping.
        guard s.filesz <= s.memsz, s.offset <= UInt64(fileSize), s.filesz <= UInt64(fileSize) - s.offset,
          s.vaddr <= UInt64.max - s.memsz, align <= 1 || s.offset % 4096 == s.vaddr % 4096
        else { throw .badSegment(i) }
        segments.append(s)
      case Self.ptGnuStack:
        let size = u64(at + 40)
        if size > 0 { stackSize = size }
      default:
        break
      }
    }
  }
}
