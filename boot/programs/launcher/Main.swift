// SPDX-License-Identifier: BSD-3-Clause

// bin/launcher, natively (M3d): the program croi's userboot starts. It
// reads bootfs's directory: every `bin/NAME` is a program a manifest may
// name, and every `etc/manifests/*.manifest` is launched (lib/launch), each
// service in a job and a process of its own, loaded from bootfs. Then it
// supervises them for good, or, given `launcher.until=SERVICE` on croi's
// command line (userboot passes it as the environment), until that service
// ends, and exits with its return code: how `td boot --test` runs a boot to
// its end.

import Bootfs
import Launch
import LibSys
import Sys

@main struct Main {
  static func fail(_ what: String) -> Never {
    print("launcher: \(what)")
    exit(1)
  }

  static func main() {
    guard let jobRaw = StartupHandles.take(ProcessArgs.info(ProcessArgs.jobDefault)),
      let bootfsRaw = StartupHandles.take(ProcessArgs.info(ProcessArgs.vmoBootfs))
    else { fail("started without a job or bootfs") }
    let job = Handle(raw: jobRaw)
    // Open for as long as the launcher runs: programs load from it.
    let bootfs = Handle(raw: bootfsRaw)

    let entries: [Bootfs.Entry]
    do throws(Status) {
      let size = try VMO.size(bootfs)
      let header = try VMO.read(bootfs, offset: 0, count: Bootfs.headerSize)
      guard let end = try? Bootfs.directoryEnd(header: header), end <= size else { fail("bootfs is malformed") }
      let directory = try VMO.read(bootfs, offset: 0, count: end)
      guard let all = try? Bootfs.entries(directory: directory, imageSize: size) else { fail("bootfs is malformed") }
      entries = all
    } catch {
      fail("can't read bootfs: \(error)")
    }

    var programs: [(name: String, entry: ProgramEntry)] = []
    var manifests: [(path: String, text: String)] = []
    for e in entries {
      if let name = e.name.dropping("bin/") {
        programs.append((name, ProgramEntry(image: bootfs.raw, offset: e.offset, length: e.length, name: e.name)))
      } else if e.name.dropping("etc/manifests/") != nil, e.name.utf8.reversed().starts(with: ".manifest".utf8.reversed()) {
        do throws(Status) {
          manifests.append((e.name, String(decoding: try VMO.read(bootfs, offset: e.offset, count: e.length), as: UTF8.self)))
        } catch {
          fail("can't read \(e.name): \(error)")
        }
      }
    }
    guard !manifests.isEmpty else { fail("no manifests in bootfs (etc/manifests)") }
    print("launcher: \(programs.count) program(s), \(manifests.count) manifest(s) in bootfs")

    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: programs, rootJob: job)
    } catch {
      fail("can't start: \(error)")
    }
    do throws(LaunchError) {
      try launcher.start(manifests)
    } catch {
      fail(error.description)
    }
    print("launcher: started")
    for line in launcher.status.split(separator: "\n") { print("launcher:   \(line)") }

    guard let until = Environment.value("launcher.until") else {
      while true { sleep(until: infiniteDeadline) }
    }
    let code: Int64
    do throws(LaunchError) {
      code = try launcher.waitForExit(until)
    } catch {
      fail(error.description)
    }
    print("launcher: \(until) exited with \(code)")
    for line in launcher.status.split(separator: "\n") { print("launcher:   \(line)") }
    launcher.stop()
    withExtendedLifetime(bootfs) {}
    exit(code)
  }
}

extension String {
  /// The rest, if it starts with `prefix` (compared as bytes: tier 0 links
  /// no Unicode tables for String's own prefix test).
  func dropping(_ prefix: String) -> String? {
    guard utf8.starts(with: prefix.utf8) else { return nil }
    return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
  }
}
