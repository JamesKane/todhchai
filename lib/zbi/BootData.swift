// SPDX-License-Identifier: BSD-3-Clause

// croi's boot data (K9b): one container in Zircon's ZBI format of what
// firmware told the loader, read from the read-only VMO userboot passes on
// (PA_VMO_BOOTDATA). Written from croi's kernel/include/zbi.h, the whole
// contract: a container header, then items, each a 32-byte header and its
// payload padded to 8 bytes. Every header carries the version flag and the
// item magic; croi sets no CRC32.

public struct BootData: Equatable, Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case truncated
    case notAContainer
    /// An item's header is malformed: its offset.
    case badItem(Int)
  }

  public struct Framebuffer: Equatable, Sendable {
    /// Physical, not necessarily page aligned.
    public var base: UInt64
    public var width: UInt32
    public var height: UInt32
    /// Pixels per scan line.
    public var stride: UInt32
    /// Zircon's zbi_pixel_format_t: `rgbx888` (byte 0 blue) or `bgr888x`
    /// (byte 0 red); bits 16-23 are the bytes per pixel.
    public var format: UInt32

    public static let rgbx888: UInt32 = 0x0004_0005
    public static let bgr888x: UInt32 = 0x0004_000B

    public init(base: UInt64, width: UInt32, height: UInt32, stride: UInt32, format: UInt32) {
      self.base = base
      self.width = width
      self.height = height
      self.stride = stride
      self.format = format
    }

    /// stride * height * 4 bytes.
    public var size: UInt64 { UInt64(stride) * UInt64(height) * 4 }
  }

  public struct MemoryRange: Equatable, Sendable {
    public enum Kind: UInt32, Equatable, Sendable {
      /// RAM the kernel owns.
      case ram = 1
      /// Device memory and the framebuffer.
      case peripheral = 2
      /// Everything else firmware described: ACPI tables and NVS, UEFI
      /// runtime, reserved.
      case reserved = 3
    }
    public var base: UInt64
    public var length: UInt64
    public var kind: Kind

    public init(base: UInt64, length: UInt64, kind: Kind) {
      self.base = base
      self.length = length
      self.kind = kind
    }

    public func contains(_ address: UInt64) -> Bool { address >= base && address - base < length }
  }

  public enum ItemType {
    public static let container: UInt32 = 0x544F_4F42  // "BOOT"
    public static let memConfig: UInt32 = 0x434D_454D  // "MEMC"
    public static let acpiRSDP: UInt32 = 0x5044_5352  // "RSDP"
    public static let smbios: UInt32 = 0x4942_4D53  // "SMBI"
    public static let framebuffer: UInt32 = 0x4246_5753  // "SWFB"
  }

  public static let containerMagic: UInt32 = 0x868C_F7E6
  public static let itemMagic: UInt32 = 0xB578_1729
  public static let flagsVersion: UInt32 = 1 << 16
  public static let headerSize = 32
  public static let alignment = 8

  /// The ACPI 2.0+ RSDP's physical address.
  public var rsdp: UInt64?
  /// The SMBIOS entry point's physical address.
  public var smbios: UInt64?
  public var framebuffer: Framebuffer?
  /// Sorted by address; holes are absent.
  public var memory: [MemoryRange] = []

  public init(rsdp: UInt64? = nil, smbios: UInt64? = nil, framebuffer: Framebuffer? = nil, memory: [MemoryRange] = []) {
    self.rsdp = rsdp
    self.smbios = smbios
    self.framebuffer = framebuffer
    self.memory = memory
  }

  /// The container's bytes needed: its header says how many follow it.
  public static func length(header: [UInt8]) throws(Failure) -> Int {
    guard header.count >= headerSize else { throw .truncated }
    guard le32(header, 0) == ItemType.container, le32(header, 8) == containerMagic,
      le32(header, 12) & flagsVersion != 0, le32(header, 24) == itemMagic
    else { throw .notAContainer }
    return headerSize + Int(le32(header, 4))
  }

  /// Reads a container. Items of types it doesn't know are skipped.
  public init(_ bytes: [UInt8]) throws(Failure) {
    let end = try Self.length(header: bytes)
    guard end <= bytes.count else { throw .truncated }
    var at = Self.headerSize
    while at < end {
      guard at + Self.headerSize <= end else { throw .badItem(at) }
      let type = Self.le32(bytes, at), length = Int(Self.le32(bytes, at + 4))
      guard Self.le32(bytes, at + 12) & Self.flagsVersion != 0, Self.le32(bytes, at + 24) == Self.itemMagic,
        length <= end - at - Self.headerSize
      else { throw .badItem(at) }
      let p = at + Self.headerSize
      switch type {
      case ItemType.acpiRSDP:
        guard length >= 8 else { throw .badItem(at) }
        rsdp = Self.le64(bytes, p)
      case ItemType.smbios:
        guard length >= 8 else { throw .badItem(at) }
        smbios = Self.le64(bytes, p)
      case ItemType.framebuffer:
        guard length >= 24 else { throw .badItem(at) }
        framebuffer = Framebuffer(base: Self.le64(bytes, p), width: Self.le32(bytes, p + 8), height: Self.le32(bytes, p + 12),
                                  stride: Self.le32(bytes, p + 16), format: Self.le32(bytes, p + 20))
      case ItemType.memConfig:
        guard length % 24 == 0 else { throw .badItem(at) }
        var r = p
        while r < p + length {
          guard let kind = MemoryRange.Kind(rawValue: Self.le32(bytes, r + 16)) else { throw .badItem(at) }
          memory.append(MemoryRange(base: Self.le64(bytes, r), length: Self.le64(bytes, r + 8), kind: kind))
          r += 24
        }
      default:
        break
      }
      at = p + (length + Self.alignment - 1) / Self.alignment * Self.alignment
    }
  }

  /// The range holding `address`, if firmware described it.
  public func range(holding address: UInt64) -> MemoryRange? { memory.first { $0.contains(address) } }

  static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
  }
  static func le64(_ b: [UInt8], _ at: Int) -> UInt64 { UInt64(le32(b, at)) | UInt64(le32(b, at + 4)) << 32 }
}
