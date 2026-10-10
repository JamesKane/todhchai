// SPDX-License-Identifier: BSD-3-Clause

// bootfs: the read-only image of files croi's loader hands the kernel and
// userboot starts the first program from. Zircon's format, without a ZBI
// around it, as croi reads it (../croi/user/userboot/Bootfs.swift):
//
//   header      magic 0xA56D3FF9, the directory's size, two zero words
//   directory   per file: the name's length with its NUL, the data's
//               length, the data's offset from the image's start (a page
//               multiple), the name and its NUL, padded to 4 bytes
//   data        each file at its offset, zero padded to a page
//
// All fields are little-endian 32-bit words. Tier 0: `td` writes images on
// the host, and the native launcher reads them.

public enum Bootfs {
  public static let magic: UInt32 = 0xA56D_3FF9
  public static let pageSize = 4096
  public static let headerSize = 16
  /// The longest name, its NUL included (Zircon's limit).
  public static let maxName = 256

  public enum Error: Swift.Error, Equatable {
    case badHeader
    case badEntry(at: Int)
    case badName(String)
    case duplicate(String)
    case tooLarge
  }

  public struct Entry: Equatable, Sendable {
    public var name: String
    /// From the image's start; a page multiple.
    public var offset: Int
    public var length: Int
  }

  /// An image holding `files`, in their order.
  public static func image(_ files: [(name: String, data: [UInt8])]) throws(Error) -> [UInt8] {
    // Names are compared as bytes: String's comparison needs Unicode
    // tables that tier 0 doesn't always link.
    var names: [[UInt8]] = []
    for f in files {
      let bytes = Array(f.name.utf8)
      guard !bytes.isEmpty, bytes.count + 1 <= maxName, !bytes.contains(0), bytes[0] != UInt8(ascii: "/") else {
        throw .badName(f.name)
      }
      if names.contains(bytes) { throw .duplicate(f.name) }
      names.append(bytes)
    }
    var directorySize = 0
    for f in files { directorySize += entrySize(f.name.utf8.count + 1) }
    var offset = align(headerSize + directorySize)
    var image: [UInt8] = []
    put(&image, magic)
    put(&image, UInt32(directorySize))
    put(&image, 0)
    put(&image, 0)
    for f in files {
      guard offset + f.data.count <= Int(UInt32.max) else { throw .tooLarge }
      let start = image.count
      put(&image, UInt32(f.name.utf8.count + 1))
      put(&image, UInt32(f.data.count))
      put(&image, UInt32(offset))
      image.append(contentsOf: f.name.utf8)
      image.append(0)
      while image.count - start < entrySize(f.name.utf8.count + 1) { image.append(0) }
      offset = align(offset + f.data.count)
    }
    for f in files {
      image.append(contentsOf: [UInt8](repeating: 0, count: align(image.count) - image.count))
      image.append(contentsOf: f.data)
    }
    image.append(contentsOf: [UInt8](repeating: 0, count: align(image.count) - image.count))
    return image
  }

  /// The image's directory, checked: every entry inside the directory and
  /// its data inside the image, at a page multiple.
  public static func entries(_ image: [UInt8]) throws(Error) -> [Entry] {
    guard let m = word(image, 0), m == magic, let size = word(image, 4),
      headerSize + Int(size) <= image.count
    else { throw .badHeader }
    let end = headerSize + Int(size)
    var at = headerSize
    var out: [Entry] = []
    while at < end {
      guard at + 12 <= end, let nameLength = word(image, at), let dataLength = word(image, at + 4),
        let dataOffset = word(image, at + 8), nameLength >= 2, Int(nameLength) <= maxName,
        at + 12 + Int(nameLength) <= end, image[at + 12 + Int(nameLength) - 1] == 0,
        Int(dataOffset) % pageSize == 0, Int(dataOffset) + Int(dataLength) <= image.count
      else { throw .badEntry(at: at) }
      let name = String(decoding: image[(at + 12)..<(at + 12 + Int(nameLength) - 1)], as: UTF8.self)
      out.append(Entry(name: name, offset: Int(dataOffset), length: Int(dataLength)))
      at += entrySize(Int(nameLength))
    }
    return out
  }

  /// The file named `name`, or nil.
  public static func find(_ name: String, in image: [UInt8]) throws(Error) -> Entry? {
    let bytes = Array(name.utf8)
    return try entries(image).first { $0.name.utf8.elementsEqual(bytes) }
  }

  static func entrySize(_ nameWithNUL: Int) -> Int { (12 + nameWithNUL + 3) & ~3 }
  static func align(_ n: Int) -> Int { (n + pageSize - 1) & ~(pageSize - 1) }

  static func put(_ image: inout [UInt8], _ v: UInt32) {
    image.append(UInt8(truncatingIfNeeded: v))
    image.append(UInt8(truncatingIfNeeded: v >> 8))
    image.append(UInt8(truncatingIfNeeded: v >> 16))
    image.append(UInt8(truncatingIfNeeded: v >> 24))
  }

  static func word(_ image: [UInt8], _ at: Int) -> UInt32? {
    guard at >= 0, at + 4 <= image.count else { return nil }
    return UInt32(image[at]) | UInt32(image[at + 1]) << 8 | UInt32(image[at + 2]) << 16 | UInt32(image[at + 3]) << 24
  }
}
