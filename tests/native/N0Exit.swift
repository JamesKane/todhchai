// SPDX-License-Identifier: BSD-3-Clause

// bin/n0-exit: N0's exit on croi (M3e), the hosted test
// (tests/milestones/N0ExitTests.swift) as a program userboot starts in the
// launcher's place. It launches bootfs's manifests (boot/native: block over
// a ramdisk, fs, catalog), each service in its own process loaded from
// bootfs, and checks what the hosted test checks: the client's catalogue
// and live query through /svc/fs, the services' trees read like files, and
// fs killed, restarted by its policy, and the client reconnected. Run by
//
//     td boot --test --next bin/n0-exit --manifests boot/native
//
// With `--cmdline n0.trace=CATEGORIES` (user categories, such as
// ipc,app) it records the run (M3f): croi's kernel rings (ipc) and a
// region for itself and each service, written out at the end for `td boot`
// to reassemble (lib/trace/session). The measures run fewer times then:
// the trace leaves through the console at ~110 KB/s.

import Fs
import Launch
import LibSys
import Node
import Sys
import Trace
import TraceSession

@main struct N0Exit {
  static func check(_ ok: Bool, _ what: StaticString, _ detail: String = "") {
    if !ok {
      print("n0-exit: FAILED: \(what)")
      for line in detail.split(separator: "\n") { print("n0-exit:   \(line)") }
      exit(1)
    }
  }

  /// Whether `text` has `line` as one of its lines.
  static func has(_ text: String, _ line: String) -> Bool {
    text.split(separator: "\n").contains { $0.utf8.elementsEqual(line.utf8) }
  }

  static func read(_ l: Launcher, _ service: String, _ path: String) -> String {
    do {
      var root = try l.open(service)
      var leaf = try root.open(path)
      return try leaf.readText()
    } catch {
      return "unreadable"
    }
  }

  /// The median and the slowest of `samples` (ns), in µs, as text.
  static func spread(_ samples: [Int64]) -> String {
    let sorted = samples.sorted()
    func us(_ ns: Int64) -> String { "\(ns / 1000).\(ns % 1000 / 100)" }
    return "median \(us(sorted[sorted.count / 2])) us, max \(us(sorted.last!)) us (\(sorted.count) runs)"
  }

  /// M3e's measures, reported (budgets come with the native trace and
  /// `td bench`): spawn to main, a cached read through fs, a live query's
  /// update. Not enforced: TCG's timings mean nothing, and this machine is
  /// shared.
  /// `runs`: how much less to run (1: all; 4 when tracing).
  static func measure(_ l: Launcher, _ programs: [(name: String, entry: ProgramEntry)], job root: borrowing Handle,
                      runs: Int) {
    // Spawn to main: a process made, loaded from bootfs and started, until
    // its main signals.
    guard let probe = programs.first(where: { $0.name == "spawn-probe" })?.entry else {
      Boot.fail("no bin/spawn-probe in bootfs")
    }
    var spawns: [Int64] = []
    do throws(Status) {
      let job = try Job.create(parent: root)
      for _ in 0..<(20 / runs) {
        let pair = try EventPair.create()
        let mine = pair.a
        let t0 = Clock.monotonic(), z = Trace.now()
        let process = try Process.create(job: job, name: "spawn-probe")
        _ = try Process.start(process, entry: probe, arg: pair.b)
        _ = try mine.wait(for: Signals.signaled, deadline: Clock.monotonic() + 2_000_000_000)
        spawns.append(Clock.monotonic() - t0)
        Trace.zone(spawnZone, since: z)
        _ = try process.wait(for: Signals.terminated)
      }
    } catch {
      Boot.fail("spawning: \(error)")
    }
    print("n0-exit: spawn to main: \(spread(spawns))")

    // Through the fs service's tree, as a client outside every namespace.
    var data: FsIPC.DirectoryClient
    do {
      var root = try l.open("fs")
      data = FsIPC.DirectoryClient(channel: try root.open("volume").takeChannel())
    } catch {
      Boot.fail("can't open fs's volume")
    }

    // A cached read: open a small file and read it all.
    var reads: [Int64] = []
    for _ in 0..<(200 / runs) {
      let t0 = Clock.monotonic(), z = Trace.now()
      guard var f = try? data.file("music/Dulaman.flac"), let bytes = try? f.readAll(), bytes.count == 13 else {
        Boot.fail("reading music/Dulaman.flac")
      }
      _ = consume f
      reads.append(Clock.monotonic() - t0)
      Trace.zone(readZone, since: z)
    }
    print("n0-exit: open and read a cached file: \(spread(reads))")

    // A live query's update: from setting the attribute that makes a file
    // match to the event's arrival.
    var updates: [Int64] = []
    do {
      var live = FsIPC.LiveQueryClient(channel: try data.live("Audio:Year >= 2001", scan: false))
      while case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000), c.kind != .current {}
      var dir = try data.makeDirectory("probe")
      for i in 0..<(20 / runs) {
        var f = try dir.makeFile("\(i)")
        let t0 = Clock.monotonic(), z = Trace.now()
        try f.setAttribute(.int64("Audio:Year", 2001))
        var arrived = false
        while !arrived, case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) {
          arrived = c.kind == .added
        }
        guard arrived else { Boot.fail("the live query missed an update") }
        updates.append(Clock.monotonic() - t0)
        Trace.zone(liveZone, since: z)
      }
    } catch {
      Boot.fail("measuring a live query")
    }
    print("n0-exit: a live query's update: \(spread(updates))")
  }

  static let spawnZone = TraceName("spawn to main")
  static let readZone = TraceName("cached read")
  static let liveZone = TraceName("live update")

  /// A recording of the run, if croi's command line asks for one.
  static func startTrace(_ l: Launcher) -> TraceSession? {
    guard let names = Environment.value("n0.trace") else { return nil }
    guard let categories = TraceCategory(names: names) else { Boot.fail("n0.trace: unknown categories \(names)") }
    guard let resource = StartupHandles.take(ProcessArgs.info(ProcessArgs.resource)) else {
      Boot.fail("n0.trace: started without the root resource")
    }
    let session: TraceSession
    do throws(Status) {
      session = try TraceSession(resource: resource, categories: categories, kernel: TraceSession.Kernel.ipc)
    } catch {
      Boot.fail("n0.trace: can't start croi's trace: \(error)")
    }
    if let mine = session.region(for: "n0-exit") { Trace.start(region: Handle(raw: mine.handle)) }
    l.extraStartupHandles = { name in session.region(for: name).map { [$0] } ?? [] }
    return session
  }

  static func main() {
    let boot = Boot()
    let l: Launcher
    do throws(Status) {
      l = try Launcher(programs: boot.programs, rootJob: boot.job)
    } catch {
      Boot.fail("can't make a launcher: \(error)")
    }
    let session = startTrace(l)
    let t0 = Clock.monotonic()
    do throws(LaunchError) {
      try l.start(boot.manifests)
    } catch {
      Boot.fail(error.description)
    }
    print("n0-exit: launched in \((Clock.monotonic() - t0) / 1000) us")
    check(l.status == "block running restarts 0\nfs running restarts 0\ncatalog running restarts 0\n", "all running",
          l.status)

    // The client's catalogue, through /svc/fs.
    let catalog = read(l, "catalog", "status")
    check(catalog.utf8.starts(with: "namespace /data /svc\nsvc fs\n".utf8), "the client's namespace", catalog)
    check(has(catalog, "live: added /music/Anam.flac"), "the live query's update", catalog)
    check(has(catalog, "Anam.flac 1990") && has(catalog, "reconnects 0"), "the catalogue", catalog)

    // The services' trees read like files.
    let fs = read(l, "fs", "status")
    check(fs.utf8.starts(with: "volume main\ndevice /svc/block/device\n".utf8), "fs's status", fs)
    check(read(l, "fs", "volume/music/Dulaman.flac") == "Dulaman.flac\n", "a song through fs's tree")
    check(has(read(l, "block", "status"), "sessions 1"), "block's status", read(l, "block", "status"))
    print("n0-exit: catalogue, live query and trees ok")
    measure(l, boot.programs, job: boot.job, runs: session == nil ? 1 : 4)

    // fs dies; its policy restarts it, and the client mounts it again.
    do throws(LaunchError) { try l.kill("fs") } catch { Boot.fail(error.description) }
    let killed = Clock.monotonic()
    var restarted = false
    while !restarted && Clock.monotonic() < killed + 3_000_000_000 {
      sleep(until: Clock.monotonic() + 1_000_000)
      restarted = has(l.status, "fs running restarts 1")
    }
    check(restarted, "fs restarted", l.status)
    print("n0-exit: fs restarted in \((Clock.monotonic() - killed) / 1000) us")
    let after = read(l, "catalog", "status")
    check(has(after, "Anam.flac 1990") && has(after, "reconnects 1"), "the client reconnected", after)
    print("n0-exit: the client reconnected; the songs are there")

    l.stop()

    // A manifest that names a missing service stops the launch.
    do throws(Status) {
      let lone = try Launcher(programs: boot.programs, rootJob: boot.job)
      var message = "started"
      do throws(LaunchError) {
        try lone.start([(path: "catalog.manifest", text: "service catalog\nprogram catalog\nuse fs\nexport\n")])
      } catch {
        message = error.description
      }
      lone.stop()
      check(message == "catalog.manifest:3: no service 'fs'", "a missing service stops the launch", message)
    } catch {
      Boot.fail("can't make a launcher: \(error)")
    }
    if let session {
      let t0 = Clock.monotonic()
      session.export { print($0) }
      print("n0-exit: trace written in \((Clock.monotonic() - t0) / 1_000_000) ms")
    }
    print("n0-exit: ok")
    _ = consume boot
    exit(0)
  }
}
