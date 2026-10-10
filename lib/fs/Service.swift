// SPDX-License-Identifier: BSD-3-Clause

// The fs service: a Taisce volume served as Directory and File channels,
// on the dispatcher's thread (filesystem.md §7). Its own tree:
//
//     status    the volume, and what is open on it
//     volume    the volume's root directory (walks go into the volume)
//
// Every change is in memory at once; a transaction group commits a second
// after the first change since the last, sooner if many blocks wait, and
// at once on Directory.sync (File.sync writes the intent log instead).
// Watches and live queries hear of changes from the change journal as each
// operation commits in memory, so they may report a change a crash then
// loses (filesystem.md §5).

import IPC
import Node
import Taisce

public final class FsService: @unchecked Sendable {
  var fs: FileSystem<RingDevice>
  let dispatcher: IPCDispatcher
  /// What `status` calls the device.
  public let device: String
  /// The timer that commits a group a second after a change.
  let timer: Handle
  var commitPending = false
  /// The journal records watchers and live queries have had.
  var journalSeen: UInt64
  /// Sessions watching their node, until they close.
  var watchers: [FsSession] = []
  var lives: [LiveState] = []

  public struct Counts: Equatable, Sendable {
    public var sessions = 0
    public var commits = 0
    public var liveQueries = 0
  }
  public internal(set) var counts = Counts()

  /// Groups wait at most this long (and this many dirty blocks).
  static let commitDelay: Int64 = 1_000_000_000
  static let commitBlocks = 4096

  public init(_ fs: consuming FileSystem<RingDevice>, device: String, dispatcher: IPCDispatcher) throws(Status) {
    self.fs = fs
    self.device = device
    self.dispatcher = dispatcher
    journalSeen = self.fs.nextSeq - 1
    let timer = try Timer.create()
    self.timer = try timer.duplicate()
    // A strong capture (Embedded Swift has no weak references): the
    // dispatcher owns the closure, and dropping its entries when the service
    // stops (removeAll) ends the cycle.
    try dispatcher.watch(timer, signals: Signals.signaled) { [self] _ in
      try? commit()
      return true
    }
  }

  /// Puts `status` and `volume` in `tree`.
  public func publish(in tree: NodeTree) {
    tree.text("status") { [self] in status }
    tree.delegate("volume") { [self] (names: [String]) throws(NodeError) in
      try walk(from: FileSystem<RingDevice>.root, names)
    }
  }

  /// A channel to the volume's root directory.
  public func root() throws(NodeError) -> Handle { try channel(FileSystem<RingDevice>.root) }

  public var status: String {
    let s = fs.engine.store.volume.superblock
    return """
      volume \(String(decoding: s.label, as: UTF8.self))
      device \(device)
      txg \(s.txg)
      sessions \(counts.sessions)
      live-queries \(lives.count)
      commits \(counts.commits)

      """
  }

  public static var now: UInt64 { UInt64(clamping: Clock.realtime()) }

  // MARK: Durability

  /// Commits a group now.
  func commit() throws(TaisceError) {
    if commitPending {
      try? Timer.cancel(timer)
      commitPending = false
    }
    try fs.sync()
    counts.commits += 1
  }

  /// After every change: watchers and live queries hear of it, and a
  /// commit is scheduled.
  func changed() {
    tell()
    if fs.engine.pendingBlocks > Self.commitBlocks {
      try? commit()
    } else if !commitPending {
      commitPending = true
      try? Timer.set(timer, deadline: Clock.monotonic() + Self.commitDelay)
    }
  }

  // MARK: Nodes and channels

  func qid(_ ino: UInt64) throws(TaisceError) -> NodeIPC.Qid {
    let inode = try fs.stat(ino)
    return NodeIPC.Qid(path: ino, version: UInt32(truncatingIfNeeded: inode.version),
                       kind: inode.type == .directory ? .directory : .file)
  }

  /// A channel to `ino`: Directory or File, as it is.
  func channel(_ ino: UInt64) throws(NodeError) -> Handle {
    let isDirectory: Bool
    do throws(TaisceError) { isDirectory = try fs.stat(ino).type == .directory } catch { throw Self.nodeError(error) }
    do throws(Status) {
      let ends = try Channel.create()
      let session = FsSession(ino: ino, service: self)
      let id: UInt64
      if isDirectory {
        id = try dispatcher.add(FsIPC.DirectoryServer(channel: ends.b, impl: DirectorySession(session: session, end: FsSessionEnd(session)))) {
          (s: inout FsIPC.DirectoryServer<DirectorySession>) throws(IPCError<Never>) in
          for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
        }
      } else {
        id = try dispatcher.add(FsIPC.FileServer(channel: ends.b, impl: FileSession(session: session, end: FsSessionEnd(session)))) {
          (s: inout FsIPC.FileServer<FileSession>) throws(IPCError<Never>) in
          for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
        }
      }
      session.id = id
      counts.sessions += 1
      return ends.a
    } catch {
      throw .io
    }
  }

  /// Walks `names` from `ino`: `..` above the root stays there. A failing
  /// first name is an error; a later one ends the walk early.
  func walk(from ino: UInt64, _ names: [String]) throws(NodeError) -> NodeIPC.Walked {
    guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
    guard names.allSatisfy({ $0 == ".." || NodeIPC.isValidName($0) }) else { throw .badName }
    var at = ino
    var qids: [NodeIPC.Qid] = []
    for (i, name) in names.enumerated() {
      do throws(TaisceError) {
        at = name == ".." ? try fs.stat(at).parent : try fs.lookup(at, Array(name.utf8))
        qids.append(try qid(at))
      } catch {
        if i == 0 { throw Self.nodeError(error) }
        return NodeIPC.Walked(qids: qids, node: nil)
      }
    }
    return NodeIPC.Walked(qids: qids, node: try channel(at))
  }

  /// The directory a path below `ino` names, and its last name.
  func parent(of path: String, below ino: UInt64) throws(FsIPC.FsError) -> (UInt64, [UInt8]) {
    var names = path.split(separator: "/").map(String.init)
    guard let last = names.popLast(), NodeIPC.isValidName(last), last != ".." else { throw .badName }
    var at = ino
    for name in names {
      guard name == ".." || NodeIPC.isValidName(name) else { throw .badName }
      do throws(TaisceError) {
        at = name == ".." ? try fs.stat(at).parent : try fs.lookup(at, Array(name.utf8))
      } catch {
        throw Self.fsError(error)
      }
    }
    return (at, Array(last.utf8))
  }

  func path(_ ino: UInt64) -> String {
    guard let p = try? fs.path(ino) else { return "" }
    return String(decoding: p, as: UTF8.self)
  }

  // MARK: Watches and live queries

  /// Passes on what the journal has gained.
  func tell() {
    guard let records = try? fs.journal(after: journalSeen), let last = records.last else { return }
    journalSeen = last.seq
    watchers.removeAll { $0.closed }
    var woken: [FsSession] = []
    for r in records {
      for s in watchers {
        if let change = Self.change(r, for: s.ino) {
          s.pending.append(change)
          if !woken.contains(where: { $0 === s }) { woken.append(s) }
        }
      }
    }
    for s in woken { dispatcher.wake(s.id) }
    lives.removeAll { $0.closed }
    for live in lives { update(live) }
  }

  /// What record `r` means to a watcher of `ino`, if anything.
  static func change(_ r: JournalEntry, for ino: UInt64) -> NodeIPC.Change? {
    let name = String(decoding: r.name, as: UTF8.self)
    if r.parent == ino && r.ino != ino {
      let kind: NodeIPC.ChangeKind =
        !r.reasons.isDisjoint(with: [.created, .linked]) ? .created
        : !r.reasons.isDisjoint(with: [.removed, .unlinked]) ? .removed : .modified
      return NodeIPC.Change(seq: r.seq, kind: kind, name: name)
    }
    if r.ino == ino {
      return NodeIPC.Change(seq: r.seq, kind: r.reasons.contains(.removed) ? .removed : .modified, name: name)
    }
    return nil
  }

  /// Watches `session`'s node, replaying what came after `seq` (0: none).
  func watch(_ session: FsSession, since seq: UInt64) throws(NodeError) -> UInt64 {
    if !watchers.contains(where: { $0 === session }) { watchers.append(session) }
    let now = fs.nextSeq - 1
    guard seq > 0, seq < now else { return now }
    do throws(TaisceError) {
      let records = try fs.journal(after: seq)
      guard records.first?.seq == seq + 1 else { throw .journalTrimmed }
      session.pending += records.prefix { $0.seq <= journalSeen }.compactMap { Self.change($0, for: session.ino) }
    } catch {
      session.pending.append(NodeIPC.Change(seq: now, kind: .overflow, name: ""))
    }
    // Sent once this reply has gone.
    if !session.pending.isEmpty { dispatcher.wake(session.id) }
    return now
  }

  /// Starts a live query: the client's end of its channel.
  func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle {
    let query: LiveQuery
    do throws(TaisceError) { query = try fs.live(Array(text.utf8), scan: scan) } catch { throw Self.fsError(error) }
    do throws(Status) {
      let ends = try Channel.create()
      let state = LiveState(query: query, text: text, scan: scan)
      state.pending = query.results.map { added($0, seq: query.seq) }
        + [FsIPC.QueryChange(kind: .current, node: 0, path: "", seq: query.seq)]
      state.id = try dispatcher.add(FsIPC.LiveQueryServer(channel: ends.b, impl: LiveSession(state: state))) {
        (s: inout FsIPC.LiveQueryServer<LiveSession>) throws(IPCError<Never>) in
        let changes = state.pending
        state.pending = []
        for c in changes { try s.sendChanged(c) }
      }
      lives.append(state)
      dispatcher.wake(state.id)
      return ends.a
    } catch {
      throw .io
    }
  }

  func added(_ ino: UInt64, seq: UInt64) -> FsIPC.QueryChange {
    FsIPC.QueryChange(kind: .added, node: ino, path: path(ino), seq: seq)
  }

  /// Brings a live query up to date; if the journal no longer reaches it,
  /// runs it again.
  func update(_ live: LiveState) {
    var changes: [FsIPC.QueryChange] = []
    do throws(TaisceError) {
      for u in try fs.update(&live.query) {
        switch u {
        case .added(let ino, let seq): changes.append(added(ino, seq: seq))
        case .removed(let ino, let seq): changes.append(FsIPC.QueryChange(kind: .removed, node: ino, path: path(ino), seq: seq))
        case .changed(let ino, let seq): changes.append(FsIPC.QueryChange(kind: .changed, node: ino, path: path(ino), seq: seq))
        }
      }
    } catch {
      guard let again = try? fs.live(Array(live.text.utf8), scan: live.scan) else { return }
      live.query = again
      changes = [FsIPC.QueryChange(kind: .reset, node: 0, path: "", seq: again.seq)]
        + again.results.map { added($0, seq: again.seq) }
        + [FsIPC.QueryChange(kind: .current, node: 0, path: "", seq: again.seq)]
    }
    guard !changes.isEmpty else { return }
    live.pending += changes
    dispatcher.wake(live.id)
  }

  // MARK: Attributes

  static func encode(_ v: AttributeValue) -> (kind: UInt8, value: [UInt8]) {
    func le<T: FixedWidthInteger>(_ x: T) -> [UInt8] { withUnsafeBytes(of: x.littleEndian) { unsafe Array($0) } }
    let value: [UInt8] = switch v {
    case .string(let b), .bytes(let b), .type(let b): b
    case .int64(let x), .time(let x): le(x)
    case .uint64(let x), .ref(let x): le(x)
    case .double(let d): le(d.bitPattern)
    case .bool(let b): [b ? 1 : 0]
    }
    return (v.kind.rawValue, value)
  }

  static func decode(_ kind: UInt8, _ b: [UInt8]) -> AttributeValue? {
    guard let kind = AttributeKind(rawValue: kind) else { return nil }
    func u64() -> UInt64? { b.count == 8 ? b.reversed().reduce(0) { $0 << 8 | UInt64($1) } : nil }
    switch kind {
    case .string: return .string(b)
    case .bytes: return .bytes(b)
    case .type: return .type(b)
    case .bool: return b.count == 1 ? .bool(b[0] != 0) : nil
    case .int64: return u64().map { .int64(Int64(bitPattern: $0)) }
    case .time: return u64().map { .time(Int64(bitPattern: $0)) }
    case .uint64: return u64().map { .uint64($0) }
    case .ref: return u64().map { .ref($0) }
    case .double: return u64().map { .double(Double(bitPattern: $0)) }
    }
  }

  func attributes(_ ino: UInt64, only names: [String]? = nil) throws(TaisceError) -> [FsIPC.Attribute] {
    var out: [FsIPC.Attribute] = []
    for (name, _) in try fs.attributes(ino) {
      let text = String(decoding: name, as: UTF8.self)
      if let names, !names.contains(text) { continue }
      guard let v = try fs.attribute(ino, name) else { continue }
      let (kind, value) = Self.encode(v)
      out.append(FsIPC.Attribute(name: text, kind: kind, value: value))
    }
    return out
  }

  // MARK: Errors

  static func nodeError(_ e: TaisceError) -> NodeError {
    switch e {
    case .notFound: .notFound
    case .exists: .exists
    case .notDirectory: .notDirectory
    case .isDirectory: .isDirectory
    case .notEmpty: .notEmpty
    case .nameTooLong: .badName
    case .invalid: .invalid
    default: .io
    }
  }

  static func fsError(_ e: TaisceError) -> FsIPC.FsError {
    switch e {
    case .notFound: .notFound
    case .exists: .exists
    case .notDirectory: .notDirectory
    case .isDirectory: .isDirectory
    case .notEmpty: .notEmpty
    case .nameTooLong: .badName
    case .invalid: .invalid
    case .noSpace: .noSpace
    case .readOnly: .readOnly
    case .badQuery: .badQuery
    case .needsIndex: .needsIndex
    case .tooLarge: .tooLarge
    default: .io
    }
  }
}

/// One channel to a node.
final class FsSession {
  let ino: UInt64
  let service: FsService
  var id: UInt64 = 0
  var pending: [NodeIPC.Change] = []

  init(ino: UInt64, service: FsService) {
    self.ino = ino
    self.service = service
  }

  func takePending() -> [NodeIPC.Change] {
    defer { pending = [] }
    return pending
  }

  /// Set when its server goes: watchers drop it then (no weak references
  /// in Embedded Swift).
  var closed = false
}

/// Held only by a session's server: when the dispatcher drops the server
/// (its channel closed), the session is closed and no longer counted.
final class FsSessionEnd {
  let session: FsSession
  init(_ session: FsSession) { self.session = session }
  deinit {
    session.closed = true
    session.service.counts.sessions -= 1
  }
}

/// A live query and what its channel hasn't sent yet.
final class LiveState {
  var query: LiveQuery
  let text: String
  let scan: Bool
  var id: UInt64 = 0
  var pending: [FsIPC.QueryChange] = []
  var closed = false

  init(query: LiveQuery, text: String, scan: Bool) {
    self.query = query
    self.text = text
    self.scan = scan
  }
}

/// A live query's channel takes no requests; when it goes, so does the query.
struct LiveSession: FsIPC.LiveQueryHandler {
  let owner: LiveOwner
  init(state: LiveState) { owner = LiveOwner(state) }
}

final class LiveOwner {
  let state: LiveState
  init(_ state: LiveState) { self.state = state }
  deinit { state.closed = true }
}
