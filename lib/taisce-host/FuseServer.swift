// SPDX-License-Identifier: BSD-3-Clause

// taisce-fuse's server: FUSE requests in, Taisce operations, replies out.
// Inode numbers are FUSE node IDs (the root is 1 in both). Typed attributes
// appear as `user.` extended attributes. A synthetic directory, /.taisce,
// holds three control files:
//
//   query  write a query, then read the paths that match, one a line
//   live   write a query, then read "+ path" for each match; reads then
//          block until the results change: "+", "-" or "~" (changed)
//          (each file remembers the last query written to it, so
//          `echo QUERY > query; cat query` works across the two opens)
//   index  write "ATTRIBUTE KIND [caseless]" to declare an index; read the
//          declared ones
//
// Durability: fsync writes the intent log; syncfs, unmount, a second with
// nothing to do, and a large transaction group commit a group.
//
// With reader threads (S1f, `startReaders`), those threads read every
// request: they answer lookups, attributes, file reads, links and xattrs
// through lock-free readers, and pass the rest to the thread in `serve`,
// the only one that writes. An open file's handle is its inode number with
// the top bit set, so a reader needs no shared handle table.

import Glibc
import Synchronization
import Taisce

public final class FuseServer<Device: BlockDevice> {
  public var fs: FileSystem<Device>
  let fd: Int32
  var handles: [UInt64: Handle] = [:]
  var nextHandle: UInt64 = 1
  /// Reads of live-query files waiting for an update: (request, handle, size).
  var waiting: [(unique: UInt64, handle: UInt64, size: Int)] = []
  var dirty = false
  public private(set) var finished = false
  /// Each live handle's results' paths, as last reported, so a removal can
  /// name what went (the node may have no path any more).
  var livePaths: [UInt64: [UInt64: [UInt8]]] = [:]
  /// The last query written to `query`, and to `live`: a later open reads
  /// it (`echo QUERY > query; cat query`).
  var lastQuery: [UInt8] = []
  var lastLive: [UInt8] = []

  /// Requests passed from reader threads, when there are any.
  var queue: RequestQueue?
  var readerThreads: [pthread_t] = []

  enum Handle {
    case directory([(name: [UInt8], ino: UInt64, type: NodeType)])
    case query(text: [UInt8], output: [UInt8]?)
    case live(text: [UInt8], query: LiveQuery?, pending: [UInt8])
    case index(text: [UInt8], output: [UInt8]?)
  }

  // The synthetic control directory and its files.
  static var controlDirectory: UInt64 { 0xFFFF_FFFF_FFFF_FF00 }
  static var queryFile: UInt64 { controlDirectory + 1 }
  static var liveFile: UInt64 { controlDirectory + 2 }
  static var indexFile: UInt64 { controlDirectory + 3 }
  static var controlName: [UInt8] { Array(".taisce".utf8) }
  static var controlFiles: [(name: [UInt8], ino: UInt64)] {
    [(Array("query".utf8), queryFile), (Array("live".utf8), liveFile), (Array("index".utf8), indexFile)]
  }

  /// Serves `fs` on `fd`: /dev/fuse, or for tests a packet socket.
  public init(_ fs: consuming FileSystem<Device>, fd: Int32) {
    self.fs = fs
    self.fd = fd
  }

  static var now: UInt64 { ToolSupport.now }

  // MARK: The loop

  /// Serves until the kernel unmounts (DESTROY, or the device goes away).
  public func serve() {
    if let queue { return serveQueue(queue) }
    var buffer = [UInt8](repeating: 0, count: (1 << 20) + 8192)
    while !finished {
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, 1000) == 0 {
        if dirty { syncNow() }  // a second with nothing to do
        continue
      }
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR || errno == EAGAIN || errno == ENOENT { continue }  // ENOENT: an interrupted request
        break  // ENODEV: unmounted
      }
      if n == 0 { break }
      for reply in handle(Array(buffer[..<n])) { send(reply) }
    }
    if dirty { syncNow() }
  }

  /// Serves what reader threads pass on, until they've all stopped
  /// (unmounted) or DESTROY.
  func serveQueue(_ queue: RequestQueue) {
    while !finished {
      var pfd = pollfd(fd: queue.wakeRead, events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, 1000) == 0 {
        if dirty { syncNow() }  // a second with nothing to do
        continue
      }
      let (messages, readers) = queue.take()
      for m in messages { for reply in handle(m) { send(reply) } }
      if readers == 0 { break }
    }
    if dirty { syncNow() }
    for t in readerThreads { ToolSupport.join(t) }
    readerThreads = []
  }

  func send(_ reply: [UInt8]) { Self.send(fd, reply) }

  static func send(_ fd: Int32, _ reply: [UInt8]) {
    _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  }

  /// A reply to request `unique` from `body`: its bytes, or its error as
  /// an errno; nil for none.
  static func reply(_ unique: UInt64, _ body: () throws -> [UInt8]?) -> [UInt8]? {
    do {
      return try body().map { FuseEncode.reply(unique, $0) }
    } catch let e as TaisceError {
      return FuseEncode.reply(unique, error: e.fuseError)
    } catch let e as FuseErrno {
      return FuseEncode.reply(unique, error: -e.code)
    } catch {
      return FuseEncode.reply(unique, error: -5)
    }
  }

  func syncNow() {
    try? fs.sync()
    dirty = false
  }

  /// One request; the replies to send (none for FORGET, or a read held for
  /// a live query; more than one when a change releases held reads).
  public func handle(_ message: [UInt8]) -> [[UInt8]] {
    guard let r = FuseRequest(message) else { return [] }
    var replies: [[UInt8]] = []
    if let reply = Self.reply(r.unique, { try dispatch(r) }) { replies.append(reply) }
    if FuseServer.mutating.contains(r.opcode) {
      dirty = true
      replies += releaseWaiting()
      if fs.engine.pendingBlocks > 4096 { syncNow() }
    }
    return replies
  }

  static var mutating: Set<UInt32> {
    Set([FuseOpcode.setattr, .symlink, .mknod, .mkdir, .unlink, .rmdir, .rename, .link, .write, .release, .setxattr,
         .removexattr, .create, .rename2].map(\.rawValue))
  }

  // MARK: Requests

  func dispatch(_ request: FuseRequest) throws -> [UInt8]? {
    var r = request.body
    let node = request.node
    let now = Self.now
    guard let op = FuseOpcode(rawValue: request.opcode) else { throw FuseErrno(38) }  // ENOSYS
    if node >= Self.controlDirectory { return try control(op, request, &r) }
    if Self.isReadOnly(op, request) { return try Self.answer(op, request, &fs) }
    switch op {
    case .initialize:
      let major = r.u32(), minor = r.u32(), readahead = r.u32(), flags = r.u32()
      _ = minor
      guard major == 7 else { throw FuseErrno(71) }  // EPROTO
      var w = FuseWriter()
      w.u32(7)
      w.u32(31)
      w.u32(readahead)
      w.u32(flags & (1 << 0 | 1 << 5 | 1 << 22))  // ASYNC_READ, BIG_WRITES, MAX_PAGES
      w.u16(16)  // max_background
      w.u16(12)  // congestion_threshold
      w.u32(1 << 20)  // max_write
      w.u32(1)  // time_gran: nanoseconds
      w.u16(256)  // max_pages
      w.zeros(FuseSize.initOut - w.bytes.count)
      return w.bytes
    case .destroy:
      syncNow()
      finished = true
      return []
    case .forget, .batchForget, .interrupt:
      return nil
    case .lookup:  // of /.taisce: the rest are read-only
      return controlEntry(Self.controlDirectory)
    case .getattr, .readlink, .getxattr, .listxattr:
      throw FuseErrno(38)  // read-only, answered above
    case .setattr:
      let valid = r.u32()
      r.skip(4 + 8)
      let size = r.u64()
      r.skip(8)
      let atime = r.u64(), mtime = r.u64()
      r.skip(8)
      let atimens = r.u32(), mtimens = r.u32()
      r.skip(4)
      let mode = r.u32()
      r.skip(4)
      let uid = r.u32(), gid = r.u32()
      if valid & FuseSetattr.size != 0 { try fs.truncate(node, size: size, now: now) }
      let at: UInt64? = valid & FuseSetattr.atimeNow != 0 ? now
        : valid & FuseSetattr.atime != 0 ? atime * 1_000_000_000 + UInt64(atimens) : nil
      let mt: UInt64? = valid & FuseSetattr.mtimeNow != 0 ? now
        : valid & FuseSetattr.mtime != 0 ? mtime * 1_000_000_000 + UInt64(mtimens) : nil
      if valid & (FuseSetattr.mode | FuseSetattr.uid | FuseSetattr.gid) != 0 || at != nil || mt != nil {
        try fs.setAttributes(node, mode: valid & FuseSetattr.mode != 0 ? mode : nil,
                             uid: valid & FuseSetattr.uid != 0 ? uid : nil,
                             gid: valid & FuseSetattr.gid != 0 ? gid : nil, atime: at, mtime: mt, now: now)
      }
      return FuseEncode.attrOut(node, try fs.stat(node))
    case .symlink:
      let name = r.name(), target = r.name()
      let ino = try fs.symlink(node, name, target: target, uid: request.uid, gid: request.gid, now: now)
      return FuseEncode.entry(ino, try fs.stat(ino))
    case .mknod:
      let mode = r.u32()
      r.skip(12)
      guard mode & 0o170000 == 0o100000 else { throw FuseErrno(1) }  // EPERM: regular files only
      let ino = try fs.create(node, r.name(), .file, mode: mode, uid: request.uid, gid: request.gid, now: now)
      return FuseEncode.entry(ino, try fs.stat(ino))
    case .mkdir:
      let mode = r.u32()
      r.skip(4)
      let ino = try fs.create(node, r.name(), .directory, mode: mode, uid: request.uid, gid: request.gid, now: now)
      return FuseEncode.entry(ino, try fs.stat(ino))
    case .unlink:
      try fs.unlink(node, r.name(), now: now)
      return []
    case .rmdir:
      try fs.rmdir(node, r.name(), now: now)
      return []
    case .rename, .rename2:
      let newDir = r.u64()
      var flags: UInt32 = 0
      if op == .rename2 {
        flags = r.u32()
        r.skip(4)
      }
      let from = r.name(), to = r.name()
      if flags & 2 != 0 { throw FuseErrno(22) }  // RENAME_EXCHANGE: not in S0
      if flags & 1 != 0, (try? fs.lookup(newDir, to)) != nil { throw TaisceError.exists }  // RENAME_NOREPLACE
      try fs.rename(node, from, newDir, to, now: now)
      return []
    case .link:
      let old = r.u64()
      try fs.link(old, node, r.name(), now: now)
      return FuseEncode.entry(old, try fs.stat(old))
    case .open:
      guard try fs.stat(node).type == .file else { throw TaisceError.isDirectory }
      fs.opened(node)
      return openReply(node | Self.fileHandle, flags: 0)
    case .create:
      r.skip(4)  // fuse_create_in: flags, then mode, umask, open_flags
      let mode = r.u32()
      r.skip(8)
      let ino = try fs.create(node, r.name(), .file, mode: mode, uid: request.uid, gid: request.gid, now: now)
      let entry = FuseEncode.entry(ino, try fs.stat(ino))
      fs.opened(ino)
      return entry + openReply(ino | Self.fileHandle, flags: 0)
    case .read:  // with a file's handle, read-only (answered above)
      throw FuseErrno(9)  // EBADF
    case .write:
      let handle = r.u64(), offset = r.u64(), size = Int(r.u32())
      r.skip(4 + 8 + 4 + 4)
      guard handle & Self.fileHandle != 0 else { throw FuseErrno(9) }
      let ino = handle & ~Self.fileHandle
      let data = Array(r.rest().prefix(size))
      try fs.write(ino, offset: offset, data, now: now)
      var w = FuseWriter()
      w.u32(UInt32(data.count))
      w.u32(0)
      return w.bytes
    case .release:
      let handle = r.u64()
      if handle & Self.fileHandle != 0 { try fs.closed(handle & ~Self.fileHandle) }
      return []
    case .flush, .access, .fsyncdir:
      return []
    case .fsync:  // fsync(2): through the intent log, no group commit
      try fs.fsync()
      return []
    case .syncfs:  // sync(1), syncfs(2): commit the group
      syncNow()
      return []
    case .statfs:
      let a = fs.engine.store.volume.allocator
      var w = FuseWriter()
      w.u64(a.blockCount)
      w.u64(a.freeCount)
      w.u64(a.freeCount)
      w.u64(fs.engine.nextInode)
      w.u64(UInt64(Int64.max))
      w.u32(4096)
      w.u32(UInt32(FileSystem<Device>.maxName))
      w.u32(4096)
      w.zeros(4 + 24)
      return w.bytes
    case .opendir:
      var entries: [(name: [UInt8], ino: UInt64, type: NodeType)] = [
        (Array(".".utf8), node, .directory), (Array("..".utf8), try fs.stat(node).parent, .directory),
      ]
      for (e, _) in try fs.list(node) { entries.append((e.name, e.ino, e.type)) }
      if node == FileSystem<Device>.root { entries.append((Self.controlName, Self.controlDirectory, .directory)) }
      return openReply(add(.directory(entries)), flags: 0)
    case .readdir:
      return try readdir(&r)
    case .releasedir:
      handles[r.u64()] = nil
      return []
    case .setxattr:
      // Without FUSE_SETXATTR_EXT (not asked for), fuse_setxattr_in is its
      // 8-byte compatible form: size, flags.
      let size = Int(r.u32())
      r.skip(4)
      let name = r.name()
      let value = Array(r.rest().prefix(size))
      try fs.setAttribute(node, try Self.attributeName(name), Self.decodeValue(value), now: now)
      return []
    case .removexattr:
      let name = r.name()
      guard try fs.removeAttribute(node, try Self.attributeName(name), now: now) else { throw FuseErrno(61) }
      return []
    }
  }

  // MARK: Read-only requests

  /// An open file's handle: its inode with this bit.
  static var fileHandle: UInt64 { 1 << 63 }

  /// Whether a lock-free reader can answer `request` (S1f): a lookup, an
  /// attribute, a link, an xattr or a file read, on an ordinary node.
  static func isReadOnly(_ op: FuseOpcode, _ request: FuseRequest) -> Bool {
    guard request.node < controlDirectory else { return false }
    var r = request.body
    switch op {
    case .getattr, .readlink, .getxattr, .listxattr: return true
    case .lookup: return !(request.node == FileSystem<Device>.root && r.name() == controlName)
    case .read: return r.u64() & fileHandle != 0
    default: return false
    }
  }

  /// Answers a read-only request from `fs`: the writer's file system, or a
  /// reader thread's snapshot.
  static func answer<R: FileReading & ~Copyable>(_ op: FuseOpcode, _ request: FuseRequest, _ fs: inout R) throws
    -> [UInt8]
  {
    var r = request.body
    let node = request.node
    switch op {
    case .lookup:
      let ino = try fs.lookup(node, r.name())
      return FuseEncode.entry(ino, try fs.stat(ino))
    case .getattr:
      return FuseEncode.attrOut(node, try fs.stat(node))
    case .readlink:
      return try fs.readlink(node)
    case .read:
      let handle = r.u64(), offset = r.u64(), size = Int(r.u32())
      return try fs.read(handle & ~fileHandle, offset: offset, count: size)
    case .getxattr:
      let size = Int(r.u32())
      r.skip(4)
      let name = r.name()
      guard name.starts(with: Array("user.".utf8)) else { throw FuseErrno(61) }  // ENODATA
      guard let v = try fs.attribute(node, Array(name.dropFirst(5))) else { throw FuseErrno(61) }
      return try sized(encodeValue(v), size)
    case .listxattr:
      let size = Int(r.u32())
      var names: [UInt8] = []
      for (n, _) in try fs.attributes(node) { names += Array("user.".utf8) + n + [0] }
      return try sized(names, size)
    default:
      throw FuseErrno(38)
    }
  }

  /// READDIR from an open directory's snapshot; offsets are positions in it.
  func readdir(_ r: inout FuseReader) throws -> [UInt8] {
    let handle = r.u64(), offset = Int(r.u64()), size = Int(r.u32())
    guard case .directory(let entries)? = handles[handle] else { throw FuseErrno(9) }
    var out: [UInt8] = []
    var i = offset
    while i < entries.count {
      let d = FuseEncode.dirent(entries[i].ino, offset: UInt64(i + 1), type: entries[i].type, name: entries[i].name)
      if out.count + d.count > size { break }
      out += d
      i += 1
    }
    return out
  }

  func add(_ h: Handle) -> UInt64 {
    let id = nextHandle
    nextHandle += 1
    handles[id] = h
    return id
  }

  /// struct fuse_open_out.
  func openReply(_ handle: UInt64, flags: UInt32) -> [UInt8] {
    var w = FuseWriter()
    w.u64(handle)
    w.u32(flags)
    w.u32(0)
    return w.bytes
  }

  /// xattr replies: the size alone when asked for 0 bytes, else the data
  /// (ERANGE if it won't fit).
  static func sized(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
    if size == 0 {
      var w = FuseWriter()
      w.u32(UInt32(data.count))
      w.u32(0)
      return w.bytes
    }
    guard data.count <= size else { throw FuseErrno(34) }
    return data
  }

  static func attributeName(_ xattr: [UInt8]) throws -> [UInt8] {
    guard xattr.starts(with: Array("user.".utf8)) else { throw FuseErrno(95) }  // EOPNOTSUPP
    return Array(xattr.dropFirst(5))
  }

  // MARK: Typed values as text

  static var kinds: [(prefix: String, kind: AttributeKind)] { [
    ("int64:", .int64), ("uint64:", .uint64), ("double:", .double), ("time:", .time), ("bool:", .bool),
    ("ref:", .ref), ("type:", .type), ("bytes:", .bytes),
  ] }

  /// A value from an xattr: "KIND:text" for typed ones, else a string (or
  /// bytes, if it isn't UTF-8).
  static func decodeValue(_ b: [UInt8]) -> AttributeValue {
    for (prefix, kind) in kinds where b.starts(with: Array(prefix.utf8)) {
      let rest = Array(b.dropFirst(prefix.utf8.count))
      let text = String(decoding: rest, as: UTF8.self)
      switch kind {
      case .int64: if let v = Int64(text) { return .int64(v) }
      case .uint64: if let v = UInt64(text) { return .uint64(v) }
      case .double: if let v = Double(text) { return .double(v) }
      case .time: if let v = Int64(text) { return .time(v) }
      case .bool: if text == "true" || text == "false" { return .bool(text == "true") }
      case .ref: if let v = UInt64(text) { return .ref(v) }
      case .type: return .type(rest)
      case .bytes: return .bytes(rest)
      case .string: break
      }
    }
    return String(validating: b, as: UTF8.self) != nil ? .string(b) : .bytes(b)
  }

  static func encodeValue(_ v: AttributeValue) -> [UInt8] {
    switch v {
    case .string(let s): s
    case .type(let s): Array("type:".utf8) + s
    case .bytes(let s): Array("bytes:".utf8) + s
    case .int64(let x): Array("int64:\(x)".utf8)
    case .uint64(let x): Array("uint64:\(x)".utf8)
    case .double(let x): Array("double:\(x)".utf8)
    case .time(let x): Array("time:\(x)".utf8)
    case .bool(let x): Array("bool:\(x)".utf8)
    case .ref(let x): Array("ref:\(x)".utf8)
    }
  }

  // MARK: The control files

  func controlEntry(_ ino: UInt64) -> [UInt8] {
    var w = FuseWriter()
    w.u64(ino)
    w.u64(0)
    w.u64(1)
    w.u64(1)
    w.u32(0)
    w.u32(0)
    w.append(controlAttr(ino))
    return w.bytes
  }

  func controlAttr(_ ino: UInt64) -> [UInt8] {
    var n = Inode(type: ino == Self.controlDirectory ? .directory : .file,
                  mode: ino == Self.controlDirectory ? 0o555 : 0o666, parent: 1, now: Self.now)
    n.uid = getuid()
    n.gid = getgid()
    return FuseEncode.attr(ino, n)
  }

  func control(_ op: FuseOpcode, _ request: FuseRequest, _ r: inout FuseReader) throws -> [UInt8]? {
    let node = request.node
    switch op {
    case .lookup:
      let name = r.name()
      guard node == Self.controlDirectory, let f = Self.controlFiles.first(where: { $0.name == name }) else {
        throw TaisceError.notFound
      }
      return controlEntry(f.ino)
    case .getattr:
      var w = FuseWriter()
      w.u64(0)  // never cached: the files' contents change
      w.u32(0)
      w.u32(0)
      w.append(controlAttr(node))
      return w.bytes
    case .setattr:
      var w = FuseWriter()
      w.u64(0)
      w.u32(0)
      w.u32(0)
      w.append(controlAttr(node))
      return w.bytes  // truncation on open for writing: nothing to do
    case .opendir:
      var entries: [(name: [UInt8], ino: UInt64, type: NodeType)] = [
        (Array(".".utf8), Self.controlDirectory, .directory), (Array("..".utf8), 1, .directory),
      ]
      for f in Self.controlFiles { entries.append((f.name, f.ino, .file)) }
      return openReply(add(.directory(entries)), flags: 0)
    case .readdir: return try readdir(&r)
    case .releasedir:
      handles[r.u64()] = nil
      return []
    case .flush, .access: return []
    case .forget, .batchForget: return nil
    case .getxattr: throw FuseErrno(61)
    case .listxattr: return try Self.sized([], Int(r.u32()))
    case .open:
      let h: Handle = switch node {
      case Self.queryFile: .query(text: [], output: nil)
      case Self.liveFile: .live(text: [], query: nil, pending: [])
      default: .index(text: [], output: nil)
      }
      return openReply(add(h), flags: 1 << 0 | 1 << 2 | 1 << 4)  // DIRECT_IO, NONSEEKABLE, STREAM
    case .write:
      let handle = r.u64()
      r.skip(8)
      let size = Int(r.u32())
      r.skip(4 + 8 + 4 + 4)
      let data = Array(r.rest().prefix(size))
      switch handles[handle] {
      case .query(let text, _)?:
        handles[handle] = .query(text: text + data, output: nil)
        lastQuery = text + data
      case .live(let text, nil, let pending)?:
        handles[handle] = .live(text: text + data, query: nil, pending: pending)
        lastLive = text + data
      case .index(let text, let output)?:
        var all = text + data
        while let nl = all.firstIndex(of: 0x0A) {
          try declare(Array(all[..<nl]))
          all.removeSubrange(...nl)
        }
        handles[handle] = .index(text: all, output: output)
      default: throw FuseErrno(9)
      }
      var w = FuseWriter()
      w.u32(UInt32(data.count))
      w.u32(0)
      return w.bytes
    case .read:
      let handle = r.u64()
      r.skip(8)
      let size = Int(r.u32())
      switch handles[handle] {
      case .query(let text, let output)?:
        var out = output ?? runQuery(text.isEmpty ? lastQuery : text)
        let chunk = Array(out.prefix(size))
        out.removeFirst(chunk.count)
        handles[handle] = .query(text: text, output: out)
        return chunk
      case .live(let text, let query, let pending)?:
        var q = query
        var buffer = pending
        if q == nil {
          do {
            let live = try fs.live(trimmed(text.isEmpty ? lastLive : text))
            for ino in live.results { buffer += line("+", ino, handle: handle) }
            q = live
          } catch {
            return Array("error: \(error)\n".utf8)
          }
        }
        if buffer.isEmpty {  // nothing new: hold the read until there is
          handles[handle] = .live(text: text, query: q, pending: [])
          waiting.append((request.unique, handle, size))
          return nil
        }
        let chunk = Array(buffer.prefix(size))
        handles[handle] = .live(text: text, query: q, pending: Array(buffer.dropFirst(chunk.count)))
        return chunk
      case .index(let text, let output)?:
        // A stream: the list once, then the end.
        var out = output ?? fs.indices.flatMap { i in
          i.name + Array(" \(i.kind)\(i.collation == .caseFolded ? " caseless" : "")\(i.building ? " (building)" : "")\n".utf8)
        }
        let chunk = Array(out.prefix(size))
        out.removeFirst(chunk.count)
        handles[handle] = .index(text: text, output: out)
        return chunk
      default: throw FuseErrno(9)
      }
    case .release:
      let handle = r.u64()
      if case .index(let text, _)? = handles[handle], !text.isEmpty { try? declare(text) }
      handles[handle] = nil
      livePaths[handle] = nil
      waiting.removeAll { $0.handle == handle }
      return []
    default:
      throw FuseErrno(1)  // EPERM: the control files are fixed
    }
  }

  func trimmed(_ text: [UInt8]) -> [UInt8] {
    var t = text
    while let last = t.last, last == 0x0A || last == 0x20 { t.removeLast() }
    return t
  }

  /// "MARK PATH\n". For a live handle, the path is remembered for later,
  /// and a removal uses the one last reported.
  func line(_ mark: String, _ ino: UInt64, handle: UInt64? = nil) -> [UInt8] {
    var path = ((try? fs.path(ino)) ?? nil) ?? Array("#\(ino)".utf8)
    if let handle {
      if mark == "-" {
        path = livePaths[handle]?.removeValue(forKey: ino) ?? path
      } else {
        livePaths[handle, default: [:]][ino] = path
      }
    }
    return Array("\(mark) ".utf8) + path + [0x0A]
  }

  func runQuery(_ text: [UInt8]) -> [UInt8] {
    do {
      var out: [UInt8] = []
      for ino in try fs.query(trimmed(text)) { out += Array(line("", ino).dropFirst()) }
      return out
    } catch {
      return Array("error: \(error)\n".utf8)
    }
  }

  /// "ATTRIBUTE KIND [caseless]": declares an index and fills it in.
  func declare(_ lineBytes: [UInt8]) throws {
    let words = lineBytes.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    guard words.count >= 2 else { return }
    let kinds: [String: AttributeKind] = ["string": .string, "int64": .int64, "uint64": .uint64, "double": .double,
                                          "time": .time, "bool": .bool, "bytes": .bytes, "ref": .ref, "type": .type]
    guard let kind = kinds[words[1]] else { throw FuseErrno(22) }
    try fs.declareIndex(Array(words[0].utf8), kind, collation: words.count > 2 && words[2] == "caseless" ? .caseFolded : .exact)
    while try !fs.backfill(budget: 1024) {}
  }

  /// Answers held live-query reads that now have something to say.
  func releaseWaiting() -> [[UInt8]] {
    var replies: [[UInt8]] = []
    for w in waiting {
      guard case .live(let text, var q?, var buffer)? = handles[w.handle] else { continue }
      if let updates = try? fs.update(&q) {
        for u in updates {
          switch u {
          case .added(let ino, _): buffer += line("+", ino, handle: w.handle)
          case .removed(let ino, _): buffer += line("-", ino, handle: w.handle)
          case .changed(let ino, _): buffer += line("~", ino, handle: w.handle)
          }
        }
      }
      handles[w.handle] = .live(text: text, query: q, pending: buffer)
    }
    var still: [(unique: UInt64, handle: UInt64, size: Int)] = []
    for w in waiting {
      guard case .live(let text, let q, let buffer)? = handles[w.handle], !buffer.isEmpty else {
        still.append(w)
        continue
      }
      let chunk = Array(buffer.prefix(w.size))
      handles[w.handle] = .live(text: text, query: q, pending: Array(buffer.dropFirst(chunk.count)))
      replies.append(FuseEncode.reply(w.unique, chunk))
    }
    waiting = still
    return replies
  }
}

/// An errno to reply with, for what TaisceError doesn't name.
struct FuseErrno: Error {
  let code: Int32
  init(_ code: Int32) { self.code = code }
}

// MARK: Reader threads (S1f)

extension FuseServer where Device: ConcurrentReadable {
  /// Starts `count` threads that read requests, answer the read-only ones
  /// through lock-free readers, and pass the rest to `serve`'s thread. Call
  /// before `serve`.
  public func startReaders(_ count: Int) {
    let queue = self.queue ?? RequestQueue()
    self.queue = queue
    for _ in 0..<count {
      guard let reader = fs.reader() else { break }
      let box = ReaderHandoff(reader)
      let fd = self.fd
      queue.readerStarted()
      readerThreads.append(ToolSupport.spawn {
        var r = box.reader.take()!
        FuseServer.readLoop(fd, &r, queue)
        queue.readerStopped()
      })
    }
  }

  /// A reader thread: until the device goes away.
  static func readLoop(_ fd: Int32, _ r: inout FileReader<Device>, _ queue: RequestQueue) {
    var buffer = [UInt8](repeating: 0, count: (1 << 20) + 8192)
    while true {
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR || errno == EAGAIN || errno == ENOENT { continue }
        return  // ENODEV: unmounted
      }
      if n == 0 { return }
      let message = Array(buffer[..<n])
      guard let request = FuseRequest(message), let op = FuseOpcode(rawValue: request.opcode),
        isReadOnly(op, request)
      else {
        queue.push(message)
        continue
      }
      let reply = Self.reply(request.unique) {
        try r.withSnapshot { (r: inout FileReader<Device>) throws -> [UInt8] in try answer(op, request, &r) }
      }
      queue.answered.add(1, ordering: .relaxed)
      if let reply { send(fd, reply) }
    }
  }

  final class ReaderHandoff: @unchecked Sendable {
    var reader: FileReader<Device>?
    init(_ reader: consuming FileReader<Device>) { self.reader = consume reader }
  }
}

/// Requests reader threads pass to the writing thread, and a pipe that
/// wakes it.
public final class RequestQueue: Sendable {
  let state = Mutex<(messages: [[UInt8]], readers: Int)>(([], 0))
  let wakeRead: Int32, wakeWrite: Int32
  /// Requests the reader threads answered themselves.
  public let answered = Atomic<Int>(0)

  init() {
    var fds: [Int32] = [-1, -1]
    if pipe(&fds) != 0 { ToolSupport.fail("pipe: \(errno)") }  // pipe2 is a GNU extension Glibc lacks
    for fd in fds {
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    wakeRead = fds[0]
    wakeWrite = fds[1]
  }

  deinit {
    close(wakeRead)
    close(wakeWrite)
  }

  func push(_ message: [UInt8]) {
    state.withLock { $0.messages.append(message) }
    wake()
  }

  func readerStarted() { state.withLock { $0.readers += 1 } }

  func readerStopped() {
    state.withLock { $0.readers -= 1 }
    wake()
  }

  func wake() {
    var b: UInt8 = 1
    _ = write(wakeWrite, &b, 1)
  }

  /// The messages waiting, and how many reader threads are still running.
  func take() -> (messages: [[UInt8]], readers: Int) {
    var drain = [UInt8](repeating: 0, count: 256)
    while drain.withUnsafeMutableBytes({ read(wakeRead, $0.baseAddress, 256) }) > 0 {}
    return state.withLock { s in
      defer { s.messages = [] }
      return (s.messages, s.readers)
    }
  }
}
