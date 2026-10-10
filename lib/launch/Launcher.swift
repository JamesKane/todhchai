// SPDX-License-Identifier: BSD-3-Clause

// The launcher (architecture §3): reads manifests, makes a job and a
// process per service, builds each process's namespace from what its
// manifest grants and nothing else, passes handles in, and restarts
// services by their manifests' policies.
//
// A process's /svc is a tree the launcher serves for it, holding only the
// services it was granted. Each name there forwards to the service's
// current instance, so after a restart a client reconnects by opening the
// path again. Restarts happen on a supervisor thread, never the
// dispatcher's: a restart waits on the restarting service, which needs the
// dispatcher to answer its startup calls.

import IPC
import Node

public final class Launcher: @unchecked Sendable {
  /// The channel to a running service's tree, used one caller at a time.
  final class Export: @unchecked Sendable {
    let mutex = Lock()
    var client: NodeIPC.NodeClient

    init(_ channel: consuming Handle) {
      client = NodeIPC.NodeClient(channel: channel)
    }

    /// A new channel to the node `names` below the service's root.
    func open(_ names: [String]) throws(NodeIPC.NodeClient.Failure) -> Handle {
      mutex.lock()
      defer { mutex.unlock() }
      let node = try client.walk(names).take()
      switch consume node {
      case .some(let h): return h
      case .none: throw .remote(.notFound)
      }
    }
  }

  /// A service and its current instance.
  final class Service: @unchecked Sendable {
    let manifest: Manifest
    let index: Int
    var job: Handle
    var process: Handle?
    var export: Export?
    /// Its /svc tree, if it uses any service.
    var svc: NodeTree?
    /// The /svc trees of the services that use it, to remount after a restart.
    var usedBy: [NodeTree] = []
    var state = "not started"
    var instances = 0
    var restarts: [Int64] = []

    /// The current instance's return code, once it has ended.
    func returnCode() -> Int64? {
      guard let raw = process?.raw else { return nil }
      let p = Handle(raw: raw)  // borrowed: `process` still owns it
      let info = try? Process.info(p)
      _ = p.release()
      return info?.returnCode
    }

    init(_ manifest: Manifest, index: Int, job: consuming Handle) {
      self.manifest = manifest
      self.index = index
      self.job = job
    }
  }

  /// A restart storm ends here: this many in `restartWindow`, and the
  /// service is left down.
  public static let maxRestarts = 5
  public static let restartWindow: Int64 = 30_000_000_000
  /// How long an exporting service has to say it is ready.
  public static let readyTimeout: Int64 = 5_000_000_000

  /// What a manifest's `program` may name (no hashed collections in tier 0).
  let programs: [(name: String, entry: ProgramEntry)]
  let dispatcher: IPCDispatcher
  let job: Handle
  let supervisor: Handle
  /// The session's /srv.
  public let board: SrvBoard
  /// The launcher's own tree: `status`.
  public let tree: NodeTree
  var statusNode: TreeNode?
  let mutex = Lock()
  var services: [Service] = []
  var stopping = false
  /// More handles for each instance a service starts, moved into it with
  /// their processargs info words (natively; hosted processes have only
  /// their Startup): a trace session's region (M3f). Set before `start`.
  public var extraStartupHandles: ((_ service: String) -> [(info: UInt32, handle: UInt32)])?
  /// What `resource` and `programs` grant (natively, from userboot), as
  /// raw handles the launcher owns: `allow` them before `start`.
  var grantableResources: [(kind: ResourceKind, handle: UInt32)] = []
  var grantableBootfs: UInt32 = 0
  /// The launcher's two threads (raw handles; 0 if not started).
  var dispatcherThread: UInt32 = 0
  var supervisorThread: UInt32 = 0
  var running = false

  public init(programs: [(name: String, entry: ProgramEntry)], rootJob: borrowing Handle) throws(Status) {
    self.programs = programs
    dispatcher = try IPCDispatcher()
    job = try Job.create(parent: rootJob)
    supervisor = try Port.create()
    board = SrvBoard(dispatcher: dispatcher)
    tree = NodeTree(dispatcher: dispatcher)
    // A strong capture (Embedded Swift has no unowned): stop() removes the
    // leaf, which ends the cycle.
    statusNode = tree.text("status", read: { [self] in status })
  }

  deinit {
    for r in grantableResources { close(raw: r.handle) }
    if grantableBootfs != 0 { close(raw: grantableBootfs) }
  }

  /// A resource that manifests may grant with `resource KIND`.
  public func allow(resource kind: ResourceKind, _ handle: consuming Handle) {
    let raw = handle.release()
    locked { grantableResources.append((kind, raw)) }
  }

  /// The bootfs that manifests may grant with `programs`.
  public func allow(bootfs: consuming Handle) {
    let raw = bootfs.release()
    locked { grantableBootfs = raw }
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    mutex.lock()
    defer { mutex.unlock() }
    return try body()
  }

  /// One line a service: its name, state and restart count.
  public var status: String {
    locked {
      services.map { "\($0.manifest.service) \($0.state) restarts \($0.instances > 0 ? $0.instances - 1 : 0)\n" }
        .joined()
    }
  }

  // MARK: Starting

  /// Reads the manifests and starts every service, each after those it
  /// uses are ready. Any error stops the launch, with its file and line.
  public func start(_ files: [(path: String, text: String)]) throws(LaunchError) {
    var manifests: [Manifest] = []
    for f in files { manifests.append(try Manifest(file: f.path, text: f.text)) }
    let order = try launchOrder(manifests, programs: programs.map { $0.name })
    for m in manifests {
      for r in m.resources where !locked({ grantableResources.contains { $0.kind == r.kind } }) {
        throw m.error(r.line, "no '\(r.kind.name)' resource to grant")
      }
      if m.programsLine != 0 && locked({ grantableBootfs }) == 0 { throw m.error(m.programsLine, "no bootfs to grant") }
    }
    startThreads()
    for m in order {
      let service: Service
      do throws(Status) {
        service = Service(m, index: services.count, job: try Job.create(parent: job))
      } catch {
        throw LaunchError("\(m.file): can't make a job: \(error)")
      }
      locked { services.append(service) }
      if m.grants.contains(where: { $0.viaSvc }) { try buildSvc(service) }
      try launch(service)
    }
  }

  func startThreads() {
    guard !running else { return }
    running = true
    dispatcherThread = (try? Thread.spawn { [self] in try? dispatcher.run() })?.release() ?? 0
    supervisorThread = (try? Thread.spawn { [self] in supervise() })?.release() ?? 0
  }

  /// The service a manifest names.
  func service(_ name: String) -> Service { locked { services.first { $0.manifest.service == name }! } }

  /// A service's /svc tree: a forwarding node for each service it uses.
  func buildSvc(_ s: Service) throws(LaunchError) {
    let svc = NodeTree(dispatcher: dispatcher)
    for g in s.manifest.grants where g.viaSvc {
      let target = service(g.service)
      guard let export = locked({ target.export }) else {
        throw s.manifest.error(g.line, "service '\(g.service)' isn't running")
      }
      do throws(NodeIPC.NodeClient.Failure) {
        svc.mount(g.service, try export.open([]), removeWhenGone: false)
      } catch {
        throw s.manifest.error(g.line, "service '\(g.service)' doesn't answer")
      }
      locked { target.usedBy.append(svc) }
    }
    locked { s.svc = svc }
  }

  /// Starts an instance of `s`, and waits for it to be ready if it exports.
  func launch(_ s: Service) throws(LaunchError) {
    let m = s.manifest
    let failed = { (what: String) -> LaunchError in
      self.locked { s.state = "failed" }
      return LaunchError("\(m.file):\(m.serviceLine): can't start '\(m.service)': \(what)")
    }
    func sys<R: ~Copyable>(_ body: () throws(Status) -> R) throws(LaunchError) -> R {
      do throws(Status) { return try body() } catch { throw failed("\(error)") }
    }
    let startup = try sys { () throws(Status) in try Channel.create() }
    let ready = try sys { () throws(Status) in try Event.create() }
    let box = StartupBox(info: LaunchIPC.StartInfo(name: m.service, args: m.args, sealed: m.sealed, mounts: 0),
                         ready: try sys { () throws(Status) in try ready.duplicate() }, board: m.srv ? board : nil)
    if m.exports {
      let ends = try sys { () throws(Status) in try Channel.create() }
      box.export = .some(ends.b)
      let export = Export(ends.a)
      locked { s.export = export }
    }
    try mounts(for: s, into: box)
    let serverEnd = startup.b, processEnd = startup.a
    do throws(Status) {
      try dispatcher.add(LaunchIPC.StartupServer(channel: serverEnd, impl: StartupSession(box: box)))
    } catch {
      throw failed("\(error)")
    }
    let process = try sys { () throws(Status) in try Process.create(job: s.job, name: m.service) }
    let extra = (extraStartupHandles?(m.service) ?? []) + (try granted(s))
    do throws(Status) {
      _ = try Process.start(process, entry: programs.first { $0.name == m.program }!.entry, arg: processEnd,
                            extra: extra)
    } catch {
      throw failed("\(error)")
    }
    try sys { () throws(Status) in
      try process.waitAsync(port: supervisor, key: UInt64(s.index + 1), signals: Signals.terminated)
    }
    let isReady = !m.exports || waitReady(ready, process)
    mutex.lock()
    s.instances += 1
    s.state = isReady ? "running" : "failed"
    s.process = .some(process)
    mutex.unlock()
    guard isReady else {
      throw LaunchError("\(m.file):\(m.serviceLine): service '\(m.service)' didn't become ready")
    }
    // Those using it reach the new instance from now on.
    for svc in locked({ s.usedBy }) {
      if let export = locked({ s.export }), let channel = try? export.open([]) {
        svc.mount(m.service, channel, removeWhenGone: false)
      }
    }
  }

  /// The handles `resource` and `programs` grant an instance of `s`, with
  /// their processargs info: duplicates of the launcher's, and a new job
  /// under the service's.
  func granted(_ s: Service) throws(LaunchError) -> [(info: UInt32, handle: UInt32)] {
    let m = s.manifest
    var extra: [(info: UInt32, handle: UInt32)] = []
    func duplicate(_ raw: UInt32, _ line: Int) throws(LaunchError) -> UInt32 {
      let borrowed = Handle(raw: raw)  // the launcher still owns it
      let copy = try? borrowed.duplicate().release()
      _ = borrowed.release()
      guard let copy else {
        for e in extra { close(raw: e.handle) }
        throw m.error(line, "can't grant it")
      }
      return copy
    }
    for r in m.resources {
      let raw = locked { grantableResources.first { $0.kind == r.kind }!.handle }
      extra.append((HandleType.info(HandleType.resource(r.kind)), try duplicate(raw, r.line)))
    }
    if m.programsLine != 0 {
      extra.append((HandleType.info(HandleType.vmoBootfs), try duplicate(locked({ grantableBootfs }), m.programsLine)))
      do throws(Status) {
        extra.append((HandleType.info(HandleType.jobDefault), try Job.create(parent: s.job).release()))
      } catch {
        for e in extra { close(raw: e.handle) }
        throw m.error(m.programsLine, "can't make a job: \(error)")
      }
    }
    return extra
  }

  /// Whether the process said it was ready before it ended or time ran out.
  func waitReady(_ ready: borrowing Handle, _ process: borrowing Handle) -> Bool {
    let deadline = Clock.monotonic() + Self.readyTimeout
    while Clock.monotonic() < deadline {
      if (try? ready.wait(for: Signals.signaled, deadline: Clock.monotonic() + 10_000_000)) != nil { return true }
      if (try? process.wait(for: Signals.terminated, deadline: 0)) != nil { return false }
    }
    return false
  }

  /// The namespace a manifest grants, in order: /svc (the services it uses),
  /// each mount, /srv.
  func mounts(for s: Service, into box: StartupBox) throws(LaunchError) {
    let m = s.manifest
    if let svc = locked({ s.svc }) {
      do throws(Status) {
        let ends = try Channel.create()
        try svc.serve(ends.b)
        box.mounts.append(PendingMount(path: "/svc", node: ends.a, placement: .replace, create: false))
      } catch {
        throw m.error(m.serviceLine, "can't serve /svc: \(error)")
      }
    }
    for g in m.grants where !g.viaSvc {
      let target = service(g.service)
      guard let export = locked({ target.export }) else {
        throw m.error(g.line, "service '\(g.service)' isn't running")
      }
      do throws(NodeIPC.NodeClient.Failure) {
        guard g.subpath.count <= NodeIPC.maxWalk else { throw .remote(.tooManyNames) }
        box.mounts.append(PendingMount(path: g.path, node: try export.open(g.subpath), placement: g.placement,
                                       create: g.create))
      } catch {
        throw m.error(g.line, "can't open '\(([g.service] + g.subpath).joined(separator: "/"))': \(error)")
      }
    }
    if m.srv {
      do throws(Status) {
        let ends = try Channel.create()
        try board.serveNode(ends.b)
        box.mounts.append(PendingMount(path: "/srv", node: ends.a, placement: .replace, create: false))
      } catch {
        throw m.error(m.serviceLine, "can't serve /srv: \(error)")
      }
    }
    box.info.mounts = UInt32(box.mounts.count)
  }

  // MARK: Supervising

  /// Waits for services to exit and restarts them as their manifests say.
  func supervise() {
    while let packet = try? Port.wait(supervisor), packet.key != 0 {
      let s = locked { services[Int(packet.key) - 1] }
      let code = locked { s.returnCode() } ?? -1
      let restart = locked { () -> Bool in
        s.process = nil
        s.state = "exited \(code)"
        guard !stopping else { return false }
        switch s.manifest.restart {
        case .never: return false
        case .onFailure: if code == 0 { return false }
        case .always: break
        }
        let now = Clock.monotonic()
        s.restarts = s.restarts.filter { now - $0 < Self.restartWindow } + [now]
        if s.restarts.count > Self.maxRestarts {
          s.state = "failed (restarted \(Self.maxRestarts) times in \(Self.restartWindow / 1_000_000_000) s)"
          return false
        }
        return true
      }
      if restart { try? launch(s) }
    }
  }

  // MARK: Using it

  /// A new channel to a running service's tree: for the hosted boot and
  /// tests, which stand outside every namespace.
  public func open(_ service: String) throws(LaunchError) -> NodeIPC.NodeClient {
    guard let s = locked({ services.first { $0.manifest.service == service } }), let export = locked({ s.export })
    else { throw LaunchError("no running service '\(service)'") }
    do throws(NodeIPC.NodeClient.Failure) {
      return NodeIPC.NodeClient(channel: try export.open([]))
    } catch {
      throw LaunchError("service '\(service)' doesn't answer: \(error)")
    }
  }

  /// A channel to a running service's tree, to mount elsewhere (devmgr's
  /// tree holds its driver hosts').
  public func channel(to service: String) throws(LaunchError) -> Handle {
    guard let s = locked({ services.first { $0.manifest.service == service } }), let export = locked({ s.export })
    else { throw LaunchError("no running service '\(service)'") }
    do throws(NodeIPC.NodeClient.Failure) {
      return try export.open([])
    } catch {
      throw LaunchError("service '\(service)' doesn't answer: \(error)")
    }
  }

  /// Waits until `service`'s current instance ends, and gives its return
  /// code: for a boot that runs a client to its end (the native launcher's
  /// `launcher.until=`).
  public func waitForExit(_ service: String) throws(LaunchError) -> Int64 {
    let found = locked { () -> (Service, UInt32, Int)? in
      guard let s = services.first(where: { $0.manifest.service == service }), let raw = s.process?.raw else {
        return nil
      }
      let borrowed = Handle(raw: raw)  // `process` still owns it
      let copy = try? borrowed.duplicate()
      _ = borrowed.release()
      guard let copy else { return nil }
      return (s, copy.release(), s.instances)
    }
    guard let (s, raw, instance) = found else { throw LaunchError("no running service '\(service)'") }
    let p = Handle(raw: raw)
    let code: Int64
    do throws(Status) {
      _ = try p.wait(for: Signals.terminated)
      code = try Process.info(p).returnCode
    } catch {
      throw LaunchError("can't wait for '\(service)': \(error)")
    }
    // Until the supervisor has seen it too (it has dropped the instance, or
    // started the next), so `status` says it ended.
    let deadline = Clock.monotonic() + 1_000_000_000
    while locked({ s.process != nil && s.instances == instance }), Clock.monotonic() < deadline {
      sleep(until: Clock.monotonic() + 1_000_000)
    }
    return code
  }

  /// Kills a running service's process, as a crash would end it: its
  /// manifest's restart policy decides what happens next. For the hosted
  /// boot and tests.
  public func kill(_ service: String) throws(LaunchError) {
    let killed = locked { () -> Bool in
      guard let s = services.first(where: { $0.manifest.service == service }), let raw = s.process?.raw else {
        return false
      }
      let p = Handle(raw: raw)  // borrowed: `process` still owns it
      let ok = (try? Sys.kill(p)) != nil
      _ = p.release()
      return ok
    }
    if !killed { throw LaunchError("no running service '\(service)'") }
  }

  /// Ends every service and the launcher's threads.
  public func stop() {
    locked { stopping = true }
    if let statusNode { tree.remove(statusNode) }
    statusNode = nil
    try? Sys.kill(job)
    guard running else { return }
    try? Port.queue(supervisor, Packet(key: 0))
    if supervisorThread != 0 { try? Thread.join(Handle(raw: supervisorThread)) }
    dispatcher.stop()
    if dispatcherThread != 0 { try? Thread.join(Handle(raw: dispatcherThread)) }
    supervisorThread = 0
    dispatcherThread = 0
    dispatcher.removeAll()
    running = false
  }
}

// MARK: Startup, served to each process

final class PendingMount: @unchecked Sendable {
  let path: String
  var node: Handle?
  let placement: LaunchIPC.Placement
  let create: Bool

  init(path: String, node: consuming Handle, placement: LaunchIPC.Placement, create: Bool) {
    self.path = path
    self.node = .some(node)
    self.placement = placement
    self.create = create
  }
}

/// What one process is given, each handle once.
final class StartupBox: @unchecked Sendable {
  var info: LaunchIPC.StartInfo
  var mounts: [PendingMount] = []
  var export: Handle?
  let ready: Handle
  let board: SrvBoard?
  var boardTaken = false

  init(info: LaunchIPC.StartInfo, ready: consuming Handle, board: SrvBoard?) {
    self.info = info
    self.ready = ready
    self.board = board
  }
}

struct StartupSession: LaunchIPC.StartupHandler {
  let box: StartupBox

  mutating func info() -> LaunchIPC.StartInfo { box.info }

  mutating func mount(_ index: UInt32) throws(LaunchIPC.StartupError) -> LaunchIPC.MountEntry {
    guard Int(index) < box.mounts.count else { throw .notFound }
    let m = box.mounts[Int(index)]
    guard let node = m.node.take() else { throw .taken }
    return LaunchIPC.MountEntry(path: m.path, node: node, placement: m.placement, create: m.create)
  }

  mutating func export() throws(LaunchIPC.StartupError) -> Handle {
    guard let h = box.export.take() else { throw .taken }
    return h
  }

  mutating func board() throws(LaunchIPC.StartupError) -> Handle {
    guard let board = box.board else { throw .notFound }
    guard !box.boardTaken else { throw .taken }
    box.boardTaken = true
    do throws(Status) {
      let ends = try Channel.create()
      try board.serveBoard(ends.b)
      return ends.a
    } catch {
      throw .notFound
    }
  }

  mutating func ready() { try? box.ready.signal(set: Signals.signaled) }
}
