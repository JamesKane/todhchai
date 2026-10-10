// SPDX-License-Identifier: BSD-3-Clause

// N0's programs, as bodies both boots run (M3e): the hosted boot's
// ProgramEntry closures (lib/hosted/Programs.swift) and the native
// programs in bootfs (boot/programs) call these with the program's
// Startup. Tier 0. What differs between the two is passed in: the block
// service's backend (an image file hosted, memory natively) and where a
// new volume's UUID comes from (croi has no random source yet).
//
// Each serves until it is killed; one that can't start exits with 1 (2
// for bad arguments).

import Block
import Fs
import IPC
import Launch
import Node
import Taisce

public enum Services {
  /// A small service: `status` says who it is and what its namespace holds.
  public static func hello(_ start: consuming Startup) throws {
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let name = start.name, ns = start.namespace
    tree.text("status", read: { "hello from \(name); namespace: \(ns.mountPoints.joined(separator: " "))\n" })
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  }

  /// The block service over `backend`, named `name` in its status.
  public static func block(_ start: consuming Startup, backend: any BlockBackend, name: String) throws {
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    BlockService(backend: backend, name: name, dispatcher: dispatcher).publish(in: tree)
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
  }

  /// The fs service over a block device in its namespace:
  ///
  ///     fs [--format LABEL] DEVICE      # DEVICE: /svc/block/device
  ///
  /// --format makes a volume labelled LABEL, with `uuid()`'s UUID, if the
  /// device holds none.
  public static func fs(_ start: consuming Startup, uuid: () -> [UInt8]) throws {
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
      fs = try FileSystem.format(device, label: Array(label!.utf8), uuid: uuid(), now: FsService.now)
    }
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let service = try FsService(fs, device: path, dispatcher: dispatcher)
    service.publish(in: tree)
    try tree.serve(try start.export())
    try start.ready()
    try dispatcher.run()
    withExtendedLifetime(service) {}
  }

  /// N0's exit, as a client: mounts the fs service's volume at /data,
  /// catalogues songs there with typed attributes, and watches a live query
  /// see one arrive. Its `status` says what it saw; reading it checks the
  /// catalogue again, and if the fs service has restarted (the channel
  /// closed), mounts the volume afresh from /svc/fs and says so.
  public static func catalog(_ start: consuming Startup) throws {
    let ns = start.namespace
    let state = CatalogState()
    try state.mount(ns)
    var data = FsIPC.DirectoryClient(channel: try ns.connect("/data"))
    if (try? data.declareIndex("Audio:Year", kind: 2, caseless: false)) == nil,
      try !data.indices().contains(where: { $0.name == "Audio:Year" })
    {
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
    let svc = ((try? ns.list("/svc").map { $0.name }) ?? []).joined(separator: " ")
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
  }

  /// "64M": 64 MiB (K, M or G, binary), or bytes.
  public static func parseSize(_ text: String) -> UInt64? {
    guard let last = text.utf8.last else { return nil }
    let unit: UInt64? = switch last {
    case UInt8(ascii: "K"): 1 << 10
    case UInt8(ascii: "M"): 1 << 20
    case UInt8(ascii: "G"): 1 << 30
    default: nil
    }
    if let unit { return UInt64(String(text.dropLast())).map { $0 * unit } }
    return UInt64(text)
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
        guard attempt == 0, (try? mount(ns)) != nil else { return "catalogue unreadable\n" }
        reconnects += 1
      }
    }
    return "catalogue unreadable\n"
  }
}
