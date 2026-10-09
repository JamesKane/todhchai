// SPDX-License-Identifier: BSD-3-Clause

// The Linux FUSE protocol, version 7, written from the kernel's UAPI
// header (include/uapi/linux/fuse.h, the protocol's specification) with no
// libfuse. Messages are little-endian structures: a request is
// fuse_in_header and the opcode's arguments; a reply is fuse_out_header
// and its result. The sizes below are checked against the host's header
// in tests/taisce-host.

import Taisce

enum FuseOpcode: UInt32 {
  case lookup = 1, forget, getattr, setattr, readlink, symlink
  case mknod = 8, mkdir, unlink, rmdir, rename, link, open, read, write, statfs, release
  case fsync = 20, setxattr, getxattr, listxattr, removexattr, flush, initialize, opendir, readdir, releasedir,
    fsyncdir
  case access = 34, create, interrupt
  case destroy = 38
  case batchForget = 42
  case rename2 = 45
  case syncfs = 50
}

enum FuseSize {
  static let inHeader = 40
  static let outHeader = 16
  static let attr = 88
  static let entryOut = 128
  static let attrOut = 104
  static let initIn = 64
  static let initOut = 64
  static let openOut = 16
  static let writeOut = 8
  static let statfsOut = 80
  static let getxattrOut = 8
  static let setattrIn = 88
  static let readIn = 40
  static let writeIn = 40
  static let createIn = 16
  static let releaseIn = 24
  static let mkdirIn = 8
  static let rename2In = 16
  static let direntHeader = 24
}

// FATTR_*: which fields a SETATTR sets.
enum FuseSetattr {
  static let mode: UInt32 = 1 << 0
  static let uid: UInt32 = 1 << 1
  static let gid: UInt32 = 1 << 2
  static let size: UInt32 = 1 << 3
  static let atime: UInt32 = 1 << 4
  static let mtime: UInt32 = 1 << 5
  static let atimeNow: UInt32 = 1 << 7
  static let mtimeNow: UInt32 = 1 << 8
}

/// Reads a request's fields in order.
struct FuseReader {
  let bytes: [UInt8]
  var at: Int

  init(_ bytes: [UInt8], at: Int = 0) {
    self.bytes = bytes
    self.at = at
  }

  var remaining: Int { bytes.count - at }

  mutating func u16() -> UInt16 { UInt16(truncatingIfNeeded: le(2)) }
  mutating func u32() -> UInt32 { UInt32(truncatingIfNeeded: le(4)) }
  mutating func u64() -> UInt64 { le(8) }

  mutating func le(_ n: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<n where at + i < bytes.count { v |= UInt64(bytes[at + i]) << (8 * i) }
    at += n
    return v
  }

  mutating func skip(_ n: Int) { at += n }

  /// A NUL-terminated name.
  mutating func name() -> [UInt8] {
    var out: [UInt8] = []
    while at < bytes.count, bytes[at] != 0 {
      out.append(bytes[at])
      at += 1
    }
    at += 1
    return out
  }

  mutating func rest() -> [UInt8] {
    defer { at = bytes.count }
    return at < bytes.count ? Array(bytes[at...]) : []
  }
}

/// Builds a reply's body.
struct FuseWriter {
  var bytes: [UInt8] = []

  mutating func u16(_ v: UInt16) { le(UInt64(v), 2) }
  mutating func u32(_ v: UInt32) { le(UInt64(v), 4) }
  mutating func i32(_ v: Int32) { le(UInt64(UInt32(bitPattern: v)), 4) }
  mutating func u64(_ v: UInt64) { le(v, 8) }
  mutating func le(_ v: UInt64, _ n: Int) { for i in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
  mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
  mutating func append(_ b: [UInt8]) { bytes += b }
  mutating func align8() { while bytes.count % 8 != 0 { bytes.append(0) } }
}

/// A request off the wire.
struct FuseRequest {
  var opcode: UInt32
  var unique: UInt64
  var node: UInt64
  var uid: UInt32
  var gid: UInt32
  var pid: UInt32
  var body: FuseReader

  init?(_ message: [UInt8]) {
    guard message.count >= FuseSize.inHeader else { return nil }
    var r = FuseReader(message)
    let length = Int(r.u32())
    guard length == message.count else { return nil }
    opcode = r.u32()
    unique = r.u64()
    node = r.u64()
    uid = r.u32()
    gid = r.u32()
    pid = r.u32()
    let extensions = Int(r.u16()) * 8
    r.skip(2)
    body = FuseReader(Array(message[..<(message.count - extensions)]), at: FuseSize.inHeader)
  }
}

enum FuseEncode {
  /// A reply: the header (with `error`, a negative errno, or 0) and body.
  static func reply(_ unique: UInt64, error: Int32 = 0, _ body: [UInt8] = []) -> [UInt8] {
    var w = FuseWriter()
    w.u32(UInt32(FuseSize.outHeader + body.count))
    w.i32(error)
    w.u64(unique)
    w.append(body)
    return w.bytes
  }

  /// struct fuse_attr for a node.
  static func attr(_ ino: UInt64, _ n: Inode) -> [UInt8] {
    var w = FuseWriter()
    w.u64(ino)
    w.u64(n.size)
    w.u64((n.size + 511) / 512)
    for t in [n.atime, n.mtime, n.ctime] { w.u64(t / 1_000_000_000) }
    for t in [n.atime, n.mtime, n.ctime] { w.u32(UInt32(t % 1_000_000_000)) }
    let type: UInt32 = switch n.type {
    case .file: 0o100000
    case .directory: 0o040000
    case .symlink: 0o120000
    }
    w.u32(type | n.mode)
    w.u32(n.links)
    w.u32(n.uid)
    w.u32(n.gid)
    w.u32(0)  // rdev
    w.u32(4096)  // blksize
    w.u32(0)  // flags
    return w.bytes
  }

  /// struct fuse_entry_out: the node, cached for a second.
  static func entry(_ ino: UInt64, _ n: Inode) -> [UInt8] {
    var w = FuseWriter()
    w.u64(ino)
    w.u64(0)  // generation: inode numbers are never reused
    w.u64(1)
    w.u64(1)
    w.u32(0)
    w.u32(0)
    w.append(attr(ino, n))
    return w.bytes
  }

  /// struct fuse_attr_out.
  static func attrOut(_ ino: UInt64, _ n: Inode) -> [UInt8] {
    var w = FuseWriter()
    w.u64(1)
    w.u32(0)
    w.u32(0)
    w.append(attr(ino, n))
    return w.bytes
  }

  /// One struct fuse_dirent, padded to 8 bytes.
  static func dirent(_ ino: UInt64, offset: UInt64, type: NodeType, name: [UInt8]) -> [UInt8] {
    var w = FuseWriter()
    w.u64(ino)
    w.u64(offset)
    w.u32(UInt32(name.count))
    w.u32(type == .directory ? 4 : type == .symlink ? 10 : 8)  // DT_DIR, DT_LNK, DT_REG
    w.append(name)
    w.align8()
    return w.bytes
  }
}

extension TaisceError {
  /// The errno a FUSE reply carries, negated.
  var fuseError: Int32 {
    let e: Int32 = switch self {
    case .notFound: 2  // ENOENT
    case .exists: 17  // EEXIST
    case .notDirectory: 20  // ENOTDIR
    case .isDirectory: 21  // EISDIR
    case .notEmpty: 39  // ENOTEMPTY
    case .nameTooLong: 36  // ENAMETOOLONG
    case .noSpace: 28  // ENOSPC
    case .tooLarge: 27  // EFBIG
    case .invalid, .badQuery, .needsIndex, .badDelta, .missingKey: 22  // EINVAL
    case .io(let errno): errno
    default: 5  // EIO
    }
    return -e
  }
}
