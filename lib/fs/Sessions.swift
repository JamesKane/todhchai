// SPDX-License-Identifier: BSD-3-Clause

// What a Directory or File channel does: Node's methods and Attributes',
// which both compose, then each one's own.

import IPC
import Node
import Taisce

/// Node's and Attributes' methods, for files and directories alike.
protocol NodeSession: NodeIPC.NodeHandler, FsIPC.AttributesHandler {
  var session: FsSession { get }
}

extension NodeSession {
  var service: FsService { session.service }
  var ino: UInt64 { session.ino }

  /// Runs a Taisce operation for Node.
  func node<T>(_ body: (FsService) throws(TaisceError) -> T) throws(NodeError) -> T {
    do throws(TaisceError) { return try body(service) } catch { throw FsService.nodeError(error) }
  }

  /// Runs a Taisce operation for Attributes.
  func fs<T>(_ body: (FsService) throws(TaisceError) -> T) throws(FsIPC.FsError) -> T {
    do throws(TaisceError) { return try body(service) } catch { throw FsService.fsError(error) }
  }

  // MARK: Node

  mutating func walk(_ names: [String]) throws(NodeError) -> NodeIPC.Walked { try service.walk(from: ino, names) }

  mutating func stat(_ fields: UInt32) throws(NodeError) -> NodeIPC.Stat {
    let ino = self.ino
    return try node { (s: FsService) throws(TaisceError) in
      let inode = try s.fs.stat(ino)
      let name = ino == FileSystem<RingDevice>.root ? "" : try s.fs.names(ino).first.map { String(decoding: $0.name, as: UTF8.self) } ?? ""
      let attributes = fields & NodeIPC.Fields.attributes == 0 ? [] : try s.attributes(ino).map {
        NodeIPC.Attribute(name: $0.name, kind: $0.kind, value: $0.value)
      }
      return NodeIPC.Stat(qid: try s.qid(ino), name: name,
                          size: fields & NodeIPC.Fields.size != 0 ? inode.size : 0,
                          modified: fields & NodeIPC.Fields.modified != 0 ? Int64(inode.mtime) : 0,
                          attributes: attributes)
    }
  }

  mutating func readdir(cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    let listing: FsIPC.Listing
    do throws(FsIPC.FsError) {
      listing = try service.list(ino, cursor: cursor, max: max, attributes: fields & NodeIPC.Fields.attributes != 0 ? nil : [])
    } catch .notDirectory {
      throw .notDirectory
    } catch {
      throw .io
    }
    let entries = listing.entries.map { e in
      NodeIPC.Stat(qid: NodeIPC.Qid(path: e.node, version: 0, kind: e.kind == NodeType.directory.rawValue ? .directory : .file),
                   name: e.name, size: fields & NodeIPC.Fields.size != 0 ? e.size : 0,
                   modified: fields & NodeIPC.Fields.modified != 0 ? e.modified : 0,
                   attributes: e.attributes.map { NodeIPC.Attribute(name: $0.name, kind: $0.kind, value: $0.value) })
    }
    return NodeIPC.DirBatch(entries: entries, next: listing.next, done: listing.done)
  }

  mutating func read(offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8] {
    let ino = self.ino
    return try node { (s: FsService) throws(TaisceError) in
      guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
      return try s.fs.read(ino, offset: offset, count: Swift.min(Int(max), NodeIPC.maxIO))
    }
  }

  mutating func write(offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32 {
    guard data.count <= NodeIPC.maxIO else { throw .invalid }
    let ino = self.ino
    try node { (s: FsService) throws(TaisceError) in
      guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
      try s.fs.write(ino, offset: offset, data, now: FsService.now)
    }
    service.changed()
    return UInt32(data.count)
  }

  mutating func watch(since seq: UInt64) throws(NodeError) -> UInt64 { try service.watch(session, since: seq) }

  mutating func create(_ name: String, kind: NodeIPC.NodeKind) throws(NodeError) -> NodeIPC.Walked {
    guard NodeIPC.isValidName(name), name != ".." else { throw .badName }
    guard kind != .service else { throw .unsupported }
    let ino = self.ino
    let child = try node { (s: FsService) throws(TaisceError) in
      try s.fs.create(ino, Array(name.utf8), kind == .directory ? .directory : .file,
                      mode: kind == .directory ? 0o755 : 0o644, now: FsService.now)
    }
    service.changed()
    let qid = try node { (s: FsService) throws(TaisceError) in try s.qid(child) }
    return NodeIPC.Walked(qids: [qid], node: try service.channel(child))
  }

  mutating func remove() throws(NodeError) {
    let ino = self.ino
    guard ino != FileSystem<RingDevice>.root else { throw .denied }
    try node { (s: FsService) throws(TaisceError) in
      guard let (dir, name) = try s.fs.names(ino).first else { throw .notFound }
      if try s.fs.stat(ino).type == .directory {
        try s.fs.rmdir(dir, name, now: FsService.now)
      } else {
        try s.fs.unlink(dir, name, now: FsService.now)
      }
    }
    service.changed()
  }

  // MARK: Attributes

  mutating func getAttribute(_ name: String) throws(FsIPC.FsError) -> FsIPC.Attribute {
    let ino = self.ino
    let value = try fs { (s: FsService) throws(TaisceError) in try s.fs.attribute(ino, Array(name.utf8)) }
    guard let value else { throw .notFound }
    let (kind, bytes) = FsService.encode(value)
    return FsIPC.Attribute(name: name, kind: kind, value: bytes)
  }

  mutating func setAttribute(_ attribute: FsIPC.Attribute) throws(FsIPC.FsError) {
    guard let value = FsService.decode(attribute.kind, attribute.value) else { throw .invalid }
    let ino = self.ino
    try fs { (s: FsService) throws(TaisceError) in
      try s.fs.setAttribute(ino, Array(attribute.name.utf8), value, now: FsService.now)
    }
    service.changed()
  }

  mutating func removeAttribute(_ name: String) throws(FsIPC.FsError) {
    let ino = self.ino
    let removed = try fs { (s: FsService) throws(TaisceError) in
      try s.fs.removeAttribute(ino, Array(name.utf8), now: FsService.now)
    }
    guard removed else { throw .notFound }
    service.changed()
  }
}

struct DirectorySession: NodeSession, FsIPC.DirectoryHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func list(cursor: UInt64, max: UInt32, attributes: [String]) throws(FsIPC.FsError) -> FsIPC.Listing {
    try service.list(ino, cursor: cursor, max: max, attributes: attributes)
  }

  mutating func rename(_ from: String, to: String) throws(FsIPC.FsError) {
    let (fromDir, fromName) = try service.parent(of: from, below: ino)
    let (toDir, toName) = try service.parent(of: to, below: ino)
    try fs { (s: FsService) throws(TaisceError) in try s.fs.rename(fromDir, fromName, toDir, toName, now: FsService.now) }
    service.changed()
  }

  mutating func query(_ text: String, scan: Bool) throws(FsIPC.FsError) -> [FsIPC.Match] {
    let found = try fs { (s: FsService) throws(TaisceError) in try s.fs.query(Array(text.utf8), scan: scan) }
    return found.map { FsIPC.Match(node: $0, path: service.path($0)) }
  }

  mutating func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle { try service.live(text, scan: scan) }

  mutating func declareIndex(_ name: String, kind: UInt8, caseless: Bool) throws(FsIPC.FsError) {
    guard let kind = AttributeKind(rawValue: kind) else { throw .invalid }
    try fs { (s: FsService) throws(TaisceError) in
      try s.fs.declareIndex(Array(name.utf8), kind, collation: caseless ? .caseFolded : .exact)
      // What was there before is indexed now, as taisce-fuse does.
      while try !s.fs.backfill(budget: 1024) {}
    }
    service.changed()
  }

  mutating func indices() -> [FsIPC.IndexInfo] {
    service.fs.indices.map {
      FsIPC.IndexInfo(name: String(decoding: $0.name, as: UTF8.self), kind: $0.kind.rawValue,
                      caseless: $0.collation == .caseFolded, building: $0.building)
    }
  }

  mutating func sync() throws(FsIPC.FsError) {
    try fs { (s: FsService) throws(TaisceError) in try s.commit() }
  }
}

struct FileSession: NodeSession, FsIPC.FileHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func resize(_ size: UInt64) throws(FsIPC.FsError) {
    let ino = self.ino
    try fs { (s: FsService) throws(TaisceError) in try s.fs.truncate(ino, size: size, now: FsService.now) }
    service.changed()
  }

  mutating func sync() throws(FsIPC.FsError) {
    try fs { (s: FsService) throws(TaisceError) in try s.fs.fsync() }
  }
}

extension FsService {
  /// Entries of directory `ino` from `cursor` (0: the start; else one more
  /// than the last listed's hash), with the attributes named (nil: all).
  /// A batch ends at a hash boundary, so entries that share one come together.
  func list(_ ino: UInt64, cursor: UInt64, max: UInt32, attributes names: [String]?) throws(FsIPC.FsError)
    -> FsIPC.Listing
  {
    let limit = Int(Swift.max(1, Swift.min(max, 256)))
    do throws(TaisceError) {
      let found = try fs.list(ino, after: cursor == 0 ? nil : cursor - 1, limit: limit)
      var entries: [FsIPC.Entry] = []
      for (e, _) in found {
        let inode = try fs.stat(e.ino)
        entries.append(FsIPC.Entry(name: String(decoding: e.name, as: UTF8.self), node: e.ino, kind: e.type.rawValue,
                                   size: inode.size, modified: Int64(inode.mtime),
                                   attributes: names == [] ? [] : try attributes(e.ino, only: names)))
      }
      let buckets = found.reduce(into: [UInt64]()) { if $0.last != $1.cookie { $0.append($1.cookie) } }
      return FsIPC.Listing(entries: entries, next: (found.last?.cookie ?? cursor) &+ 1, done: buckets.count < limit)
    } catch {
      throw Self.fsError(error)
    }
  }
}
