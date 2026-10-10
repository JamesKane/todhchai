// SPDX-License-Identifier: BSD-3-Clause

// The SDK helper that publishes a tree over Node (architecture §6, the
// equivalent of lib9p's in-memory file tree). A service builds the tree,
// with text leaves for `status` and `ctl`, and serves channels to it:
//
//     let dispatcher = try IPCDispatcher()
//     let tree = NodeTree(dispatcher: dispatcher)
//     tree.text("status") { "running \(jobs) jobs\n" }
//     tree.text("ctl", read: { "" }, write: { command throws(NodeIPC.NodeError) in try run(command) })
//     tree.service("device") { channel in try serveDevice(channel) }
//     try tree.serve(channel)
//     try dispatcher.run()
//
// Requests are served on the dispatcher's thread. The service may change
// the tree from any thread; watchers hear of it.

import Glibc
import IPC

public typealias NodeError = NodeIPC.NodeError

/// A node of a NodeTree.
public final class TreeNode: @unchecked Sendable {
  enum Content {
    case directory(allowsCreate: Bool)
    case bytes([UInt8], writable: Bool)
    case text(read: @Sendable () -> String, write: (@Sendable (String) throws(NodeError) -> Void)?)
    /// Another service's node: walks into it go there.
    case remote(Remote)
    /// A typed protocol: a walk to it gets a channel `connect` serves.
    case service(connect: (consuming Handle) throws(Status) -> Void)
  }

  public let name: String
  let path: UInt64
  var version: UInt32 = 0
  var content: Content
  weak var parent: TreeNode?
  var children: [TreeNode] = []
  var modified = realtime()
  var attributes: [NodeIPC.Attribute] = []
  /// Made by a client, so a client may remove it.
  var removable = false
  var detached = false
  var watchers: [Watcher] = []
  /// The last changes watchers heard, for watch(since:); `lostThrough` is
  /// the newest one dropped from it.
  var log: [NodeIPC.Change] = []
  var lostThrough: UInt64 = 0

  init(name: String, path: UInt64, content: Content) {
    self.name = name
    self.path = path
    self.content = content
  }

  var kind: NodeIPC.NodeKind {
    switch content {
    case .directory, .remote: .directory
    case .bytes, .text: .file
    case .service: .service
    }
  }
  var qid: NodeIPC.Qid { NodeIPC.Qid(path: path, version: version, kind: kind) }
}

/// A channel to another service's node, which a tree forwards walks to.
final class Remote: @unchecked Sendable {
  let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  var client: NodeIPC.NodeClient
  /// Whether the node goes when the other service does (a post on a
  /// board), or stays to be given a new channel (a launcher's /svc).
  let removeWhenGone: Bool

  init(_ channel: consuming Handle, removeWhenGone: Bool) {
    client = NodeIPC.NodeClient(channel: channel)
    self.removeWhenGone = removeWhenGone
    pthread_mutex_init(mutex, nil)
  }

  deinit {
    pthread_mutex_destroy(mutex)
    mutex.deallocate()
  }

  /// Walks `names` from the remote node, one caller at a time.
  func walk(_ names: [String]) throws(NodeIPC.NodeClient.Failure) -> NodeIPC.Walked {
    pthread_mutex_lock(mutex)
    defer { pthread_mutex_unlock(mutex) }
    return try client.walk(names)
  }
}

/// A session watching a node; it goes when the session's channel does.
final class Watcher: @unchecked Sendable {
  weak var session: SessionState?
  init(_ session: SessionState) { self.session = session }
}

/// What a session shares with the tree: its dispatcher id and its queue.
final class SessionState: @unchecked Sendable {
  var id: UInt64 = 0
  var pending: [NodeIPC.Change] = []
}

public final class NodeTree: @unchecked Sendable {
  public let root: TreeNode
  let dispatcher: IPCDispatcher
  let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  var lastPath: UInt64 = 1
  var seq: UInt64 = 0
  static let logLength = 64

  public init(dispatcher: IPCDispatcher) {
    self.dispatcher = dispatcher
    root = TreeNode(name: "", path: 1, content: .directory(allowsCreate: false))
    pthread_mutex_init(mutex, nil)
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    pthread_mutex_lock(mutex)
    defer { pthread_mutex_unlock(mutex) }
    return try body()
  }

  // MARK: Building

  /// The directory at `path`, made (with any parents) if need be.
  @discardableResult
  public func directory(_ path: String, allowsCreate: Bool = false) -> TreeNode {
    let node = place(path, .directory(allowsCreate: allowsCreate))
    locked { if case .directory = node.content { node.content = .directory(allowsCreate: allowsCreate) } }
    return node
  }

  /// A file holding `bytes`.
  @discardableResult
  public func file(_ path: String, _ bytes: [UInt8], writable: Bool = false) -> TreeNode {
    place(path, .bytes(bytes, writable: writable))
  }

  /// A text leaf: `read` renders it on every read; `write`, if given, takes
  /// each write as one command (a `ctl` leaf).
  @discardableResult
  public func text(_ path: String, read: @escaping @Sendable () -> String,
                   write: (@Sendable (String) throws(NodeError) -> Void)? = nil) -> TreeNode {
    place(path, .text(read: read, write: write))
  }

  /// A typed protocol at `path`: a walk that ends there makes a channel and
  /// hands one end to `connect` (on the dispatcher's thread) to serve, and
  /// the other to the client. Walks can't go through it.
  @discardableResult
  public func service(_ path: String, connect: @escaping (consuming Handle) throws(Status) -> Void) -> TreeNode {
    place(path, .service(connect: connect))
  }

  /// Another service's node at `path`: walks into it are forwarded there.
  /// Mounting again where one is gives it the new channel. If the other
  /// service goes, the node goes too, unless `removeWhenGone` is false: then
  /// walks into it fail with `io` until it is mounted again.
  @discardableResult
  public func mount(_ path: String, _ channel: consuming Handle, removeWhenGone: Bool = true) -> TreeNode {
    let remote = Remote(channel, removeWhenGone: removeWhenGone)
    if let existing = node(path) {
      let replaced = locked { () -> [Watcher]? in
        guard case .remote = existing.content, !existing.detached else { return nil }
        existing.content = .remote(remote)
        return modifiedLocked(existing)
      }
      if let replaced {
        wake(replaced)
        return existing
      }
    }
    return place(path, .remote(remote))
  }

  /// The node at `path`, if there is one.
  public func node(_ path: String) -> TreeNode? {
    locked {
      var at: TreeNode? = root
      for name in path.split(separator: "/") { at = at?.children.first { $0.name == name } }
      return at
    }
  }

  /// Replaces a file's bytes.
  public func setContents(_ node: TreeNode, _ bytes: [UInt8]) {
    let woken = locked {
      if case .bytes(_, let writable) = node.content { node.content = .bytes(bytes, writable: writable) }
      return modifiedLocked(node)
    }
    wake(woken)
  }

  /// Sets a node's attributes.
  public func setAttributes(_ node: TreeNode, _ attributes: [NodeIPC.Attribute]) {
    wake(locked {
      node.attributes = attributes
      return modifiedLocked(node)
    })
  }

  /// Says a node changed (a text leaf whose rendering did): a new version,
  /// and watchers hear of it.
  public func touch(_ node: TreeNode) { wake(locked { modifiedLocked(node) }) }

  /// Removes a node and everything under it.
  public func remove(_ node: TreeNode) { wake(locked { removeLocked(node) }) }

  /// The node at `path`, made with `content` (and parent directories).
  func place(_ path: String, _ content: TreeNode.Content) -> TreeNode {
    let names = path.split(separator: "/").map(String.init)
    precondition(!names.isEmpty && names.allSatisfy(NodeIPC.isValidName), "bad path \(path)")
    var woken: [Watcher] = []
    let node = locked { () -> TreeNode in
      var at = root
      for (i, name) in names.enumerated() {
        if let child = at.children.first(where: { $0.name == name }) {
          at = child
          continue
        }
        let last = i == names.count - 1
        let (child, w) = addLocked(name, to: at, last ? content : .directory(allowsCreate: false))
        woken += w
        at = child
      }
      return at
    }
    wake(woken)
    return node
  }

  // MARK: Changes (under the lock)

  func addLocked(_ name: String, to parent: TreeNode, _ content: TreeNode.Content) -> (TreeNode, [Watcher]) {
    lastPath += 1
    let child = TreeNode(name: name, path: lastPath, content: content)
    child.parent = parent
    parent.children.append(child)
    parent.version &+= 1
    parent.modified = realtime()
    return (child, notifyLocked(parent, .created, name))
  }

  func modifiedLocked(_ node: TreeNode) -> [Watcher] {
    node.version &+= 1
    node.modified = realtime()
    var woken = notifyLocked(node, .modified, node.name)
    if let parent = node.parent { woken += notifyLocked(parent, .modified, node.name) }
    return woken
  }

  func removeLocked(_ node: TreeNode) -> [Watcher] {
    guard let parent = node.parent, !node.detached else { return [] }
    parent.children.removeAll { $0 === node }
    parent.version &+= 1
    var woken = notifyLocked(node, .removed, node.name) + notifyLocked(parent, .removed, node.name)
    func detach(_ n: TreeNode) {
      n.detached = true
      n.children.forEach(detach)
    }
    detach(node)
    for child in node.children { woken += notifyLocked(child, .removed, child.name) }
    return woken
  }

  /// Logs a change to `node` and queues it for its watchers: those to wake.
  func notifyLocked(_ node: TreeNode, _ kind: NodeIPC.ChangeKind, _ name: String) -> [Watcher] {
    seq += 1
    let change = NodeIPC.Change(seq: seq, kind: kind, name: name)
    node.log.append(change)
    if node.log.count > Self.logLength { node.lostThrough = node.log.removeFirst().seq }
    node.watchers.removeAll { $0.session == nil }
    for w in node.watchers { w.session?.pending.append(change) }
    return node.watchers
  }

  /// Asks the dispatcher to send what the watchers have queued.
  func wake(_ watchers: [Watcher]) {
    for w in watchers { if let s = w.session { dispatcher.wake(s.id) } }
  }

  // MARK: Serving

  /// Serves Node on `channel`, at the root.
  public func serve(_ channel: consuming Handle) throws(Status) { try serve(channel, at: root) }

  /// Serves Node on `channel`, at `node`.
  public func serve(_ channel: consuming Handle, at node: TreeNode) throws(Status) {
    let state = SessionState()
    let server = NodeIPC.NodeServer(channel: channel, impl: Session(tree: self, node: node, state: state))
    state.id = try dispatcher.add(server) { [self] (s: inout NodeIPC.NodeServer<Session>) throws(IPCError<Never>) in
      let changes = locked { () -> [NodeIPC.Change] in
        defer { state.pending = [] }
        return state.pending
      }
      for c in changes { try s.sendChanged(c) }
    }
  }
}

/// Nanoseconds since the Unix epoch.
func realtime() -> Int64 {
  var ts = timespec()
  clock_gettime(CLOCK_REALTIME, &ts)
  return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
}

/// One channel's view of the tree: the node it is at.
struct Session: NodeIPC.NodeHandler {
  let tree: NodeTree
  var node: TreeNode
  let state: SessionState

  /// The node, if it is still in the tree.
  func current() throws(NodeError) -> TreeNode {
    guard !node.detached else { throw .notFound }
    return node
  }

  mutating func walk(_ names: [String]) throws(NodeError) -> NodeIPC.Walked {
    guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
    guard names.allSatisfy({ $0 == ".." || NodeIPC.isValidName($0) }) else { throw .badName }
    let (qids, end, rest) = try tree.locked { () throws(NodeError) -> ([NodeIPC.Qid], TreeNode?, [String]) in
      var at = try current()
      var qids: [NodeIPC.Qid] = []
      for (i, name) in names.enumerated() {
        if case .remote = at.content, i > 0 { return (qids, at, Array(names[i...])) }
        let next: TreeNode?
        if name == ".." {
          next = at.parent ?? at
        } else if at.kind != .directory {
          if i == 0 { throw .notDirectory }
          next = nil
        } else {
          next = at.children.first { $0.name == name }
        }
        guard let next else {
          if i == 0 { throw .notFound }
          return (qids, nil, [])
        }
        at = next
        qids.append(at.qid)
      }
      return (qids, at, [])
    }
    guard let end else { return NodeIPC.Walked(qids: qids, node: nil) }
    switch end.content {
    case .remote(let remote): return try forward(rest, to: remote, at: end, after: qids)
    case .service(let connect): return NodeIPC.Walked(qids: qids, node: try connection(connect))
    default: return NodeIPC.Walked(qids: qids, node: try channel(to: end))
    }
  }

  /// Walks the rest of a walk in another service, whose node `end` is.
  func forward(_ rest: [String], to remote: Remote, at end: TreeNode, after qids: [NodeIPC.Qid]) throws(NodeError)
    -> NodeIPC.Walked
  {
    do throws(NodeIPC.NodeClient.Failure) {
      let walked = try remote.walk(rest)
      let node = walked.node
      return NodeIPC.Walked(qids: qids + walked.qids, node: node)
    } catch .remote(let e) {
      // Its first name failed: the walk ends where the remote node is.
      if qids.isEmpty { throw e }
      return NodeIPC.Walked(qids: qids, node: nil)
    } catch {
      // The other service is gone: so is its node, or it waits for another.
      guard remote.removeWhenGone else { throw .io }
      tree.remove(end)
      if qids.count <= 1 { throw .notFound }
      return NodeIPC.Walked(qids: Array(qids.dropLast()), node: nil)
    }
  }

  /// A new channel served at `node`: the client's end.
  func channel(to node: TreeNode) throws(NodeError) -> Handle {
    do throws(Status) {
      let ends = try Channel.create()
      try tree.serve(ends.b, at: node)
      return ends.a
    } catch {
      throw .io
    }
  }

  /// A new channel a service node's `connect` serves: the client's end.
  func connection(_ connect: (consuming Handle) throws(Status) -> Void) throws(NodeError) -> Handle {
    do throws(Status) {
      let ends = try Channel.create()
      try connect(ends.b)
      return ends.a
    } catch {
      throw .io
    }
  }

  func stat(_ node: TreeNode, _ fields: UInt32) -> NodeIPC.Stat {
    var size: UInt64 = 0
    if fields & NodeIPC.Fields.size != 0, case .bytes(let b, _) = node.content { size = UInt64(b.count) }
    return NodeIPC.Stat(
      qid: node.qid, name: node.name, size: size,
      modified: fields & NodeIPC.Fields.modified != 0 ? node.modified : 0,
      attributes: fields & NodeIPC.Fields.attributes != 0 ? node.attributes : [])
  }

  mutating func stat(_ fields: UInt32) throws(NodeError) -> NodeIPC.Stat {
    try tree.locked { () throws(NodeError) in stat(try current(), fields) }
  }

  mutating func readdir(cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    try tree.locked { () throws(NodeError) in
      let at = try current()
      guard at.kind == .directory else { throw .notDirectory }
      var entries: [NodeIPC.Stat] = []
      var i = Int(clamping: cursor)
      var bytes = 0
      // A batch stays well inside one message.
      while i < at.children.count, entries.count < Int(Swift.max(1, Swift.min(max, 256))), bytes < 32_768 {
        let s = stat(at.children[i], fields)
        bytes += 64 + s.name.utf8.count + s.attributes.reduce(0) { $0 + 48 + $1.name.utf8.count + $1.value.count }
        entries.append(s)
        i += 1
      }
      return NodeIPC.DirBatch(entries: entries, next: UInt64(i), done: i >= at.children.count)
    }
  }

  mutating func read(offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8] {
    let content = try tree.locked { () throws(NodeError) in try current().content }
    let bytes: [UInt8]
    switch content {
    case .directory, .remote: throw .isDirectory
    case .service: throw .unsupported
    case .bytes(let b, _): bytes = b
    case .text(let render, _): bytes = Array(render().utf8)  // outside the lock: it's the service's code
    }
    guard offset < UInt64(bytes.count) else { return [] }
    let start = Int(offset)
    return Array(bytes[start..<Swift.min(bytes.count, start + Swift.min(Int(max), NodeIPC.maxIO))])
  }

  mutating func write(offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32 {
    guard data.count <= NodeIPC.maxIO else { throw .invalid }
    let content = try tree.locked { () throws(NodeError) in try current().content }
    switch content {
    case .directory, .remote:
      throw .isDirectory
    case .service:
      throw .unsupported
    case .text(_, let write):
      guard let write else { throw .unsupported }
      guard let command = String(validating: data, as: UTF8.self) else { throw .invalid }
      try write(command)
    case .bytes:
      let node = self.node
      let woken = try tree.locked { () throws(NodeError) -> [Watcher] in
        guard case .bytes(var bytes, let writable) = node.content, !node.detached else { throw .notFound }
        guard writable else { throw .unsupported }
        guard offset <= UInt64(bytes.count) + UInt64(NodeIPC.maxIO) else { throw .invalid }
        let start = Int(offset)
        if bytes.count < start + data.count { bytes += [UInt8](repeating: 0, count: start + data.count - bytes.count) }
        bytes.replaceSubrange(start..<(start + data.count), with: data)
        node.content = .bytes(bytes, writable: writable)
        return tree.modifiedLocked(node)
      }
      tree.wake(woken)
    }
    return UInt32(data.count)
  }

  mutating func watch(since seq: UInt64) throws(NodeError) -> UInt64 {
    let state = self.state
    let (now, replay) = try tree.locked { () throws(NodeError) -> (UInt64, Bool) in
      let at = try current()
      if !at.watchers.contains(where: { $0.session === state }) { at.watchers.append(Watcher(state)) }
      guard seq > 0 else { return (tree.seq, false) }
      if at.lostThrough > seq {
        state.pending.append(NodeIPC.Change(seq: tree.seq, kind: .overflow, name: at.name))
      }
      state.pending += at.log.filter { $0.seq > seq }
      return (tree.seq, !state.pending.isEmpty)
    }
    // Sent once this reply has gone.
    if replay { tree.dispatcher.wake(state.id) }
    return now
  }

  mutating func create(_ name: String, kind: NodeIPC.NodeKind) throws(NodeError) -> NodeIPC.Walked {
    guard NodeIPC.isValidName(name) else { throw .badName }
    guard kind != .service else { throw .unsupported }
    let (child, woken) = try tree.locked { () throws(NodeError) -> (TreeNode, [Watcher]) in
      let at = try current()
      guard case .directory(let allowsCreate) = at.content else { throw .notDirectory }
      guard allowsCreate else { throw .unsupported }
      guard !at.children.contains(where: { $0.name == name }) else { throw .exists }
      let content: TreeNode.Content = kind == .directory ? .directory(allowsCreate: true) : .bytes([], writable: true)
      let (child, woken) = tree.addLocked(name, to: at, content)
      child.removable = true
      return (child, woken)
    }
    tree.wake(woken)
    return NodeIPC.Walked(qids: [child.qid], node: try channel(to: child))
  }

  mutating func remove() throws(NodeError) {
    let woken = try tree.locked { () throws(NodeError) -> [Watcher] in
      let at = try current()
      guard at.removable else { throw .denied }
      guard at.children.isEmpty else { throw .notEmpty }
      return tree.removeLocked(at)
    }
    tree.wake(woken)
  }
}
