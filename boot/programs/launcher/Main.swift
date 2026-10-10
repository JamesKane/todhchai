// SPDX-License-Identifier: BSD-3-Clause

// bin/launcher, natively (M3d): the program croi's userboot starts. It
// launches every manifest in bootfs (Boot.swift), each service in a job and
// a process of its own, loaded from bootfs. Then it supervises them for
// good, or, given `launcher.until=SERVICE` on croi's command line (userboot
// passes it as the environment), until that service ends, and exits with
// its return code: how `td boot --test` runs a boot to its end.

import Launch
import LibSys
import Sys

@main struct Main {
  static func main() {
    let boot = Boot()
    guard !boot.manifests.isEmpty else { Boot.fail("no manifests in bootfs (etc/manifests)") }
    print("launcher: \(boot.programs.count) program(s), \(boot.manifests.count) manifest(s) in bootfs")

    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: boot.programs, rootJob: boot.job)
    } catch {
      Boot.fail("can't start: \(error)")
    }
    do throws(LaunchError) {
      try launcher.start(boot.manifests)
    } catch {
      Boot.fail(error.description)
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
      Boot.fail(error.description)
    }
    print("launcher: \(until) exited with \(code)")
    for line in launcher.status.split(separator: "\n") { print("launcher:   \(line)") }
    launcher.stop()
    _ = consume boot
    exit(code)
  }
}
