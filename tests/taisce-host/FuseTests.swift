// SPDX-License-Identifier: BSD-3-Clause

// taisce-fuse's protocol, without mounting: the structure sizes against the
// host's <linux/fuse.h>, and requests straight into the server.

import FuseLayoutC
import Glibc
import Taisce
@testable import TaisceHost
import Testing

@Test func ourStructuresAreTheKernels() {
  let ours: [(String, Int)] = [
    ("fuse_in_header", FuseSize.inHeader), ("fuse_out_header", FuseSize.outHeader), ("fuse_attr", FuseSize.attr),
    ("fuse_entry_out", FuseSize.entryOut), ("fuse_attr_out", FuseSize.attrOut), ("fuse_init_in", FuseSize.initIn),
    ("fuse_init_out", FuseSize.initOut), ("fuse_open_out", FuseSize.openOut), ("fuse_write_out", FuseSize.writeOut),
    ("fuse_statfs_out", FuseSize.statfsOut), ("fuse_getxattr_out", FuseSize.getxattrOut),
    ("fuse_setattr_in", FuseSize.setattrIn), ("fuse_read_in", FuseSize.readIn), ("fuse_write_in", FuseSize.writeIn),
    ("fuse_create_in", FuseSize.createIn), ("fuse_release_in", FuseSize.releaseIn), ("fuse_mkdir_in", FuseSize.mkdirIn),
    ("fuse_rename2_in", FuseSize.rename2In), ("fuse_dirent", FuseSize.direntHeader), ("compat_setxattr_in", 8),
  ]
  for (name, size) in ours { #expect(fuse_layout_size(name) == size, "\(name)") }
  // The fields the server reads past others to reach.
  for (field, at) in [("create_in.mode", 4), ("setattr_in.size", 16), ("setattr_in.mode", 68), ("setattr_in.uid", 76),
                      ("write_in.size", 16), ("init_out.max_write", 20), ("init_out.max_pages", 28), ("attr.mode", 60)] {
    #expect(fuse_layout_offset(field) == at, "\(field)")
  }
}

/// Builds requests and reads replies.
struct Client {
  var unique: UInt64 = 0

  mutating func request(_ op: FuseOpcode, node: UInt64, _ body: [UInt8]) -> [UInt8] {
    unique += 1
    var w = FuseWriter()
    w.u32(UInt32(FuseSize.inHeader + body.count))
    w.u32(op.rawValue)
    w.u64(unique)
    w.u64(node)
    w.u32(getuid())
    w.u32(getgid())
    w.u32(1)
    w.u32(0)
    return w.bytes + body
  }

  static func name(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

  /// The reply's error and body.
  static func parse(_ reply: [UInt8]) -> (error: Int32, body: [UInt8]) {
    var r = FuseReader(reply)
    _ = r.u32()
    let e = Int32(bitPattern: r.u32())
    _ = r.u64()
    return (e, r.rest())
  }
}

func le<T: FixedWidthInteger>(_ b: [UInt8], _ at: Int, _: T.Type) -> T {
  var v: T = 0
  for i in 0..<MemoryLayout<T>.size { v |= T(b[at + i]) << (8 * i) }
  return v
}

func server() throws -> FuseServer<MemoryDevice> {
  FuseServer(try FileSystem.format(MemoryDevice(blocks: 4096), label: [], uuid: Array(1...16), now: 1), fd: -1)
}

@Test func filesGoThroughTheProtocol() throws {
  let s = try server()
  var c = Client()
  func call(_ op: FuseOpcode, _ node: UInt64, _ body: [UInt8]) -> (error: Int32, body: [UInt8]) {
    let replies = s.handle(c.request(op, node: node, body))
    return replies.isEmpty ? (0, []) : Client.parse(replies[0])
  }
  // INIT: version 7, a megabyte a write.
  var w = FuseWriter()
  w.u32(7); w.u32(45); w.u32(1 << 17); w.u32(1 << 0 | 1 << 5 | 1 << 22); w.zeros(48)
  let initReply = call(.initialize, 0, w.bytes)
  #expect(initReply.error == 0 && le(initReply.body, 0, UInt32.self) == 7 && le(initReply.body, 20, UInt32.self) == 1 << 20)
  // CREATE /a.txt with mode 0644, then WRITE and READ it back.
  w = FuseWriter(); w.u32(0o101); w.u32(0o100644); w.u32(0o022); w.u32(0)
  let created = call(.create, 1, w.bytes + Client.name("a.txt"))
  #expect(created.error == 0)
  let ino = le(created.body, 0, UInt64.self)
  #expect(le(created.body, 40 + 60, UInt32.self) == 0o100644)  // attr.mode, past entry_out's 40 bytes
  let handle = le(created.body, FuseSize.entryOut, UInt64.self)
  w = FuseWriter(); w.u64(handle); w.u64(0); w.u32(5); w.u32(0); w.u64(0); w.u32(0); w.u32(0)
  #expect(le(call(.write, ino, w.bytes + Array("hello".utf8)).body, 0, UInt32.self) == 5)
  w = FuseWriter(); w.u64(handle); w.u64(1); w.u32(100); w.u32(0); w.u64(0); w.u32(0); w.u32(0)
  #expect(call(.read, ino, w.bytes).body == Array("ello".utf8))
  // LOOKUP and errors.
  #expect(le(call(.lookup, 1, Client.name("a.txt")).body, 0, UInt64.self) == ino)
  #expect(call(.lookup, 1, Client.name("missing")).error == -2)  // ENOENT
  #expect(call(.unlink, 1, Client.name("missing")).error == -2)
  #expect(call(.rmdir, 1, Client.name("a.txt")).error == -20)  // ENOTDIR
  // SETXATTR (the 8-byte compatible header) and GETXATTR, typed.
  w = FuseWriter(); w.u32(10); w.u32(0)
  #expect(call(.setxattr, ino, w.bytes + Client.name("user.u:year") + Array("int64:1993".utf8)).error == 0)
  w = FuseWriter(); w.u32(64); w.u32(0)
  #expect(call(.getxattr, ino, w.bytes + Client.name("user.u:year")).body == Array("int64:1993".utf8))
  #expect(try s.fs.attribute(ino, Array("u:year".utf8)) == .int64(1993))
  w = FuseWriter(); w.u32(0); w.u32(0)
  #expect(le(call(.getxattr, ino, w.bytes + Client.name("user.u:year")).body, 0, UInt32.self) == 10)  // the size alone
  #expect(call(.setxattr, ino, FuseWriter().bytes + [1, 0, 0, 0, 0, 0, 0, 0] + Client.name("trusted.x") + [1]).error == -95)
  // READDIR: ".", "..", the file, and /.taisce.
  let opened = call(.opendir, 1, [0, 0, 0, 0, 0, 0, 0, 0])
  let dh = le(opened.body, 0, UInt64.self)
  w = FuseWriter(); w.u64(dh); w.u64(0); w.u32(4096); w.u32(0); w.u64(0); w.u32(0); w.u32(0)
  let listing = call(.readdir, 1, w.bytes).body
  var names: [String] = []
  var at = 0
  while at + 24 <= listing.count {
    let len = Int(le(listing, at + 16, UInt32.self))
    names.append(String(decoding: listing[(at + 24)..<(at + 24 + len)], as: UTF8.self))
    at += (24 + len + 7) / 8 * 8
  }
  #expect(names == [".", "..", "a.txt", ".taisce"])
  try s.fs.check()
}

@Test func controlFilesQueryAndHoldLiveReads() throws {
  let s = try server()
  var c = Client()
  func call(_ op: FuseOpcode, _ node: UInt64, _ body: [UInt8]) -> [[UInt8]] { s.handle(c.request(op, node: node, body)) }
  let ctl = FuseServer<MemoryDevice>.self
  func open(_ file: UInt64) -> UInt64 { le(Client.parse(call(.open, file, [0, 0, 0, 0, 0, 0, 0, 0])[0]).body, 0, UInt64.self) }
  func write(_ file: UInt64, _ h: UInt64, _ text: String) {
    var w = FuseWriter(); w.u64(h); w.u64(0); w.u32(UInt32(text.utf8.count)); w.u32(0); w.u64(0); w.u32(0); w.u32(0)
    _ = call(.write, file, w.bytes + Array(text.utf8))
  }
  func readRequest(_ file: UInt64, _ h: UInt64) -> [UInt8] {
    var w = FuseWriter(); w.u64(h); w.u64(0); w.u32(4096); w.u32(0); w.u64(0); w.u32(0); w.u32(0)
    return c.request(.read, node: file, w.bytes)
  }
  _ = try s.fs.create(1, Array("x.mp3".utf8), .file, mode: 0o644, now: 2)
  // The query file, across two opens (as `echo QUERY > query; cat query`).
  write(ctl.queryFile, open(ctl.queryFile), "name == \"x*\"\n")
  let answer = s.handle(readRequest(ctl.queryFile, open(ctl.queryFile)))
  #expect(Client.parse(answer[0]).body == Array("/x.mp3\n".utf8))
  // The live file: the current results, then a read held until a change.
  write(ctl.liveFile, open(ctl.liveFile), "name == \"*.mp3\" && size >= 0\n")
  let live = open(ctl.liveFile)
  #expect(Client.parse(s.handle(readRequest(ctl.liveFile, live))[0]).body == Array("+ /x.mp3\n".utf8))
  let held = readRequest(ctl.liveFile, live)
  #expect(s.handle(held).isEmpty)  // nothing new: no reply yet
  var w = FuseWriter(); w.u32(0); w.u32(0o100644); w.u32(0); w.u32(0)
  let replies = call(.create, 1, w.bytes + Client.name("y.mp3"))
  #expect(replies.count == 2)  // the create's, and the held read's
  #expect(Client.parse(replies[1]).body == Array("+ /y.mp3\n".utf8))
}
