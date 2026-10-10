// SPDX-License-Identifier: BSD-3-Clause

// A process's namespace (architecture §5): paths to Node channels. There is
// no global root: `/svc/<name>` holds the services a process was granted,
// `/data` its own directory, `/vol/<name>` the volumes it may see, `/srv`
// its session's board. Following Plan 9, a path can hold a union of
// channels, each mounted before, after or replacing what is there, one
// marked for creating in. Unions are resolved here, in the client.

import Glibc
import IPC

public enum NamespaceError: Error, Equatable, Sendable {
  /// A path that isn't absolute or holds a bad name.
  case badPath
  /// Nothing is mounted where the path leads.
  case notFound
  /// The namespace is sealed: it can't attach a new channel.
  case sealed
  /// A union holds at most `Namespace.maxUnion` channels.
  case unionFull
  /// No member of the union may be created in.
  case cantCreate
  /// The service answered with an error.
  case node(NodeIPC.NodeError)
  /// The channel failed.
  case transport(Status)
  /// The service broke the protocol.
  case wire(WireError)

  init(_ e: NodeIPC.NodeClient.Failure) {
    switch e {
    case .remote(.notFound): self = .notFound
    case .remote(let n): self = .node(n)
    case .transport(let s): self = .transport(s)
    case .wire(let w): self = .wire(w)
    }
  }
}

public final class Namespace: @unchecked Sendable {
  public enum Placement: Sendable {
    /// The new channel alone.
    case replace
    /// Looked in first.
    case before
    /// Looked in last.
    case after
  }

  /// One channel of a union: calls on it go one at a time.
  final class Member: @unchecked Sendable {
    let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    var client: NodeIPC.NodeClient
    let create: Bool

    init(_ client: consuming NodeIPC.NodeClient, create: Bool) {
      self.client = client
      self.create = create
      pthread_mutex_init(mutex, nil)
    }

    deinit {
      pthread_mutex_destroy(mutex)
      mutex.deallocate()
    }

    func use<R: ~Copyable>(_ body: (inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) -> R)
      throws(NodeIPC.NodeClient.Failure) -> R
    {
      pthread_mutex_lock(mutex)
      defer { pthread_mutex_unlock(mutex) }
      return try body(&client)
    }

    /// A new client at `names` below this member's node.
    func open(_ names: [String]) throws(NodeIPC.NodeClient.Failure) -> NodeIPC.NodeClient {
      try use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        names.isEmpty ? try NodeIPC.NodeClient(walked: try c.walk([])) : try c.open(names.joined(separator: "/"))
      }
    }
  }

  struct Mount {
    var path: [String]
    var members: [Member]
  }

  /// The most channels one union holds.
  public static let maxUnion = 8

  let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  var mounts: [Mount] = []
  public private(set) var sealed: Bool

  public init(sealed: Bool = false) {
    self.sealed = sealed
    pthread_mutex_init(mutex, nil)
  }

  deinit {
    pthread_mutex_destroy(mutex)
    mutex.deallocate()
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    pthread_mutex_lock(mutex)
    defer { pthread_mutex_unlock(mutex) }
    return try body()
  }

  /// A path's names, cleaned as Plan 9 does: "." dropped, ".." taking off
  /// the name before it (and nothing at the root).
  public static func clean(_ path: String) throws(NamespaceError) -> [String] {
    guard path.hasPrefix("/") else { throw .badPath }
    var names: [String] = []
    for part in path.split(separator: "/") {
      let name = String(part)
      if name == "." { continue }
      if name == ".." {
        _ = names.popLast()
        continue
      }
      guard NodeIPC.isValidName(name) else { throw .badPath }
      names.append(name)
    }
    return names
  }

  // MARK: Changing it

  /// Seals the namespace: from now on it can't attach a channel received
  /// from elsewhere (`mount`), though it can still rearrange what it holds
  /// (`bind`). Children inherit the seal. Plan 9's RFNOMNT.
  public func seal() { locked { sealed = true } }

  /// Attaches `channel` (a Node channel) at `path`. `create` marks it as
  /// where new files go in a union.
  public func mount(_ channel: consuming Handle, at path: String, _ placement: Placement = .replace,
                    create: Bool = false) throws(NamespaceError) {
    let names = try Self.clean(path)
    let member = Member(NodeIPC.NodeClient(channel: channel), create: create)
    try locked { () throws(NamespaceError) in
      guard !sealed else { throw .sealed }
      try add(member, at: names, placement)
    }
  }

  /// Binds what `source` names now at `path` too: Plan 9's bind. Allowed in
  /// a sealed namespace, since it attaches nothing new.
  public func bind(_ source: String, at path: String, _ placement: Placement = .replace,
                   create: Bool = false) throws(NamespaceError) {
    let names = try Self.clean(path)
    let member = Member(try open(source), create: create)
    try locked { () throws(NamespaceError) in try add(member, at: names, placement) }
  }

  /// Under the lock.
  func add(_ member: Member, at names: [String], _ placement: Placement) throws(NamespaceError) {
    guard let i = mounts.firstIndex(where: { $0.path == names }) else {
      mounts.append(Mount(path: names, members: [member]))
      return
    }
    switch placement {
    case .replace: mounts[i].members = [member]
    case .before, .after:
      guard mounts[i].members.count < Self.maxUnion else { throw .unionFull }
      if placement == .before { mounts[i].members.insert(member, at: 0) } else { mounts[i].members.append(member) }
    }
  }

  /// Takes away everything mounted at `path`.
  public func unmount(_ path: String) throws(NamespaceError) {
    let names = try Self.clean(path)
    try locked { () throws(NamespaceError) in
      guard let i = mounts.firstIndex(where: { $0.path == names }) else { throw .notFound }
      mounts.remove(at: i)
    }
  }

  /// The paths something is mounted at, sorted.
  public var mountPoints: [String] {
    locked { mounts.map { "/" + $0.path.joined(separator: "/") }.sorted() }
  }

  /// A namespace for a child: the same mounts, each a new channel to the
  /// same node, sealed if this one is.
  public func clone() throws(NamespaceError) -> Namespace {
    let copy = Namespace(sealed: locked { sealed })
    for m in locked({ mounts }) {
      var members: [Member] = []
      for member in m.members {
        do throws(NodeIPC.NodeClient.Failure) {
          members.append(Member(try member.open([]), create: member.create))
        } catch {
          throw NamespaceError(error)
        }
      }
      copy.mounts.append(Mount(path: m.path, members: members))
    }
    return copy
  }

  // MARK: Using it

  /// The mount `names` lead into (the longest mounted prefix) and the rest.
  func resolve(_ names: [String]) -> (members: [Member], rest: [String])? {
    locked {
      var best: Mount?
      for m in mounts where m.path.count <= names.count && Array(names.prefix(m.path.count)) == m.path {
        if best == nil || m.path.count > best!.path.count { best = m }
      }
      guard let best else { return nil }
      return (best.members, Array(names.dropFirst(best.path.count)))
    }
  }

  /// A channel to the service node at `path`, which speaks its typed
  /// protocol (`/svc/block/device`).
  public func connect(_ path: String) throws(NamespaceError) -> Handle {
    try open(path).takeChannel()
  }

  /// A channel to the node at `path`: from the first member of its union
  /// that has it.
  public func open(_ path: String) throws(NamespaceError) -> NodeIPC.NodeClient {
    let names = try Self.clean(path)
    guard let (members, rest) = resolve(names) else { throw .notFound }
    var failure = NamespaceError.notFound
    for member in members {
      do throws(NodeIPC.NodeClient.Failure) {
        return try member.open(rest)
      } catch {
        failure = NamespaceError(error)
        // A miss tries the next member; anything else is the answer.
        if failure != .notFound { throw failure }
      }
    }
    throw failure
  }

  /// The entries at `path`: the union's members' listings merged, the
  /// first member's entry winning a name, then mount points below it.
  public func list(_ path: String, fields: UInt32 = NodeIPC.Fields.all) throws(NamespaceError) -> [NodeIPC.Stat] {
    let names = try Self.clean(path)
    var entries: [NodeIPC.Stat] = []
    var found = false
    if let (members, rest) = resolve(names) {
      for member in members {
        do throws(NodeIPC.NodeClient.Failure) {
          var dir = try member.open(rest)
          found = true
          for e in try dir.list(fields: fields) where !entries.contains(where: { $0.name == e.name }) {
            entries.append(e)
          }
        } catch {
          let e = NamespaceError(error)
          if e != .notFound { throw e }
        }
      }
    }
    // Mount points below the path show as directories.
    let below = locked {
      mounts.filter { $0.path.count > names.count && Array($0.path.prefix(names.count)) == names }
        .map { $0.path[names.count] }
    }
    for name in below where !entries.contains(where: { $0.name == name }) {
      found = true
      entries.append(NodeIPC.Stat(qid: NodeIPC.Qid(path: 0, version: 0, kind: .directory), name: name, size: 0,
                                  modified: 0, attributes: []))
    }
    guard found || names.isEmpty else { throw .notFound }
    return entries
  }

  /// Creates a node at `path` and opens it: at a union's mount point, in
  /// its member marked for creating; deeper, where the parent is.
  public func create(_ path: String, kind: NodeIPC.NodeKind) throws(NamespaceError) -> NodeIPC.NodeClient {
    let names = try Self.clean(path)
    guard let name = names.last else { throw .badPath }
    let parent = Array(names.dropLast())
    guard let (members, rest) = resolve(parent) else { throw .notFound }
    var dir: NodeIPC.NodeClient
    if rest.isEmpty {
      guard let member = members.first(where: { $0.create }) else { throw .cantCreate }
      do throws(NodeIPC.NodeClient.Failure) { dir = try member.open([]) } catch { throw NamespaceError(error) }
    } else {
      dir = try open("/" + parent.joined(separator: "/"))
    }
    do throws(NodeIPC.NodeClient.Failure) {
      return try NodeIPC.NodeClient(walked: try dir.create(name, kind: kind))
    } catch {
      throw NamespaceError(error)
    }
  }
}
