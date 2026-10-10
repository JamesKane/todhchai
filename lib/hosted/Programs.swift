// SPDX-License-Identifier: BSD-3-Clause

// The programs a hosted boot can start, by the name manifests give in
// `program`. Natively, these are images in bootfs (M3).

import Block
import Fs
import Glibc
import IPC
import Launch
import Node
import Taisce

/// Every hosted program, by name.
public let hostedPrograms: [(name: String, entry: ProgramEntry)] = [
  ("hello", hello),
  ("block", block),
  ("fs", fsProgram),
  ("catalog", catalog),
]

/// A small service: `status` says who it is and what its namespace holds.
let hello = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let name = start.name, ns = start.namespace
    tree.text("status", read: { "hello from \(name); namespace: \(ns.mountPoints.joined(separator: " "))\n" })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

/// The block service over an image file:
///
///     block [--create SIZE] [--read-only] IMAGE
///
/// --create makes the image (and its directory) if need be, and sizes it:
/// SIZE in bytes, or with K, M or G (binary).
let block = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    var path: String?, size: UInt64?, readOnly = false
    var args = start.args[...]
    while let arg = args.popFirst() {
      switch arg {
      case "--create":
        guard let s = args.popFirst().flatMap(parseSize) else { Process.exit(code: 2) }
        size = s
      case "--read-only": readOnly = true
      default: path = arg
      }
    }
    guard let path else { Process.exit(code: 2) }
    if size != nil { makeDirectories(containing: path) }
    let backend = try FileBackend(path: path, blocks: size.map { $0 / 4096 }, readOnly: readOnly)
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    BlockService(backend: backend, name: path, dispatcher: dispatcher).publish(in: tree)
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

/// "64M": 64 MiB.
func parseSize(_ text: String) -> UInt64? {
  let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
  guard let last = text.last else { return nil }
  if let unit = units[last] { return UInt64(text.dropLast()).map { $0 * unit } }
  return UInt64(text)
}

/// mkdir -p for a file's directory.
func makeDirectories(containing path: String) {
  var at = path.startIndex
  while let slash = path[at...].dropFirst().firstIndex(of: "/") {
    mkdir(String(path[..<slash]), 0o755)
    at = slash
  }
}

/// The fs service over a block device in its namespace:
///
///     fs [--format LABEL] DEVICE      # DEVICE: /svc/block/device
///
/// --format makes a volume labelled LABEL if the device holds none.
let fsProgram = ProgramEntry { handle in
  do {
    var start = try Startup(handle)
    var path: String?, label: String?
    var args = start.args[...]
    while let arg = args.popFirst() {
      if arg == "--format" {
        guard let l = args.popFirst() else { Process.exit(code: 2) }
        label = l
      } else {
        path = arg
      }
    }
    guard let path else { Process.exit(code: 2) }
    let device = try RingDevice(try BlockClient(try start.namespace.connect(path)))
    var fs: FileSystem<RingDevice>
    do throws(TaisceError) {
      fs = try FileSystem.mount(device)
    } catch .notAVolume where label != nil {
      var uuid = [UInt8](repeating: 0, count: 16)
      var random = SystemRandomNumberGenerator()
      for i in uuid.indices { uuid[i] = random.next() }
      fs = try FileSystem.format(device, label: Array(label!.utf8), uuid: uuid, now: FsService.now)
    }
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let service = try FsService(fs, device: path, dispatcher: dispatcher)
    service.publish(in: tree)
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
    withExtendedLifetime(service) {}
  } catch {
    Process.exit(code: 1)
  }
}

/// N0's exit, as a client: mounts the fs service's volume at /data,
/// catalogues songs there with typed attributes, and watches a live query
/// see one arrive. Its `status` says what it saw; reading it checks the
/// catalogue again, and if the fs service has restarted (the channel
/// closed), mounts the volume afresh from /svc/fs and says so.
let catalog = ProgramEntry { handle in
  do {
    let start = try Startup(handle)
    let ns = start.namespace
    let state = CatalogState()
    try state.mount(ns)
    var data = FsIPC.DirectoryClient(channel: try ns.connect("/data"))
    if (try? data.declareIndex("Audio:Year", kind: 2, caseless: false)) == nil, try !data.indices().contains(where: { $0.name == "Audio:Year" }) {
      Process.exit(code: 3)
    }
    var music: FsIPC.DirectoryClient
    do { music = try data.directory("music") } catch { music = try data.makeDirectory("music") }
    // A song the live query will see arrive: gone first, if a boot before
    // this one left it.
    try? music.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
      var song = try c.open("Anam.flac")
      try song.remove()
    }
    var live = FsIPC.LiveQueryClient(channel: try data.live("Audio:Year >= 1990", scan: false))
    while case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000), c.kind != .current {}
    for (name, year) in [("Dulaman.flac", Int64(1976)), ("Anam.flac", 1990)] {
      var song: FsIPC.FileClient
      do { song = try music.file(name) } catch { song = try music.makeFile(name) }
      try song.write(Array("\(name)\n".utf8))
      try song.setAttribute(.string("Audio:Artist", "Clannad"))
      try song.setAttribute(.int64("Audio:Year", year))
    }
    var seen = "nothing"
    while case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) {
      if c.kind == .added {
        seen = "added \(c.path)"
        break
      }
    }
    try data.sync()
    let svc = ((try? ns.list("/svc").map(\.name)) ?? []).joined(separator: " ")
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let mounts = ns.mountPoints.joined(separator: " "), saw = seen
    tree.text("status", read: {
      "namespace \(mounts)\nsvc \(svc)\nlive: \(saw)\n\(state.check(ns))reconnects \(state.reconnects)\n"
    })
    var exported = start
    try tree.serve(try exported.export())
    try exported.ready()
    try dispatcher.run()
  } catch {
    Process.exit(code: 1)
  }
}

/// The catalogue's mount of the volume, remade when its channel closes.
final class CatalogState: @unchecked Sendable {
  var reconnects = 0

  /// Mounts /svc/fs/volume at /data, waiting up to 2 s for a restarting
  /// service.
  func mount(_ ns: Namespace) throws(NamespaceError) {
    var last = NamespaceError.notFound
    for _ in 0..<200 {
      do throws(NamespaceError) {
        try ns.mount(try ns.connect("/svc/fs/volume"), at: "/data", .replace)
        return
      } catch {
        last = error
        sleep(until: Clock.monotonic() + 10_000_000)
      }
    }
    throw last
  }

  /// What the catalogue holds: a song's year, read through /data, after
  /// remounting if the old channel is dead.
  func check(_ ns: Namespace) -> String {
    for attempt in 0..<2 {
      do {
        var data = FsIPC.DirectoryClient(channel: try ns.connect("/data"))
        var song = try data.file("music/Anam.flac")
        let year = try song.getAttribute("Audio:Year").int64Value ?? 0
        return "Anam.flac \(year)\n"
      } catch {
        guard attempt == 0, (try? mount(ns)) != nil else { return "catalogue unreadable: \(error)\n" }
        reconnects += 1
      }
    }
    return "catalogue unreadable\n"
  }
}
