// SPDX-License-Identifier: BSD-3-Clause

// The hosted boot: what userboot and the launcher are natively, in one
// Linux process. Reads every `*.manifest` in a directory, starts the
// launcher over them, prints its status, and runs until Ctrl-C.
//
//   hostboot [--check] [DIR]      # DIR defaults to boot/manifests
//
// --check starts everything, prints the status and stops: for scripts.

import FoundationEssentials
import Glibc
import HostedPrograms
import Launch
import Sys

func fail(_ message: String) -> Never {
  let line = Array("hostboot: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
  exit(1)
}

var check = false
var dir = "boot/manifests"
for arg in CommandLine.arguments.dropFirst() {
  if arg == "--check" { check = true } else if arg.hasPrefix("-") { fail("unknown option \(arg)") } else { dir = arg }
}

guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { fail("can't read \(dir)") }
let files = names.filter { $0.hasSuffix(".manifest") }.sorted().map { name in
  let path = dir.hasSuffix("/") ? dir + name : dir + "/" + name
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
  return (path: path, text: text)
}
if files.isEmpty { fail("no manifests in \(dir)") }

// Ctrl-C is taken with sigwait, so no handler runs on some other thread:
// block it before any thread starts, so every thread inherits the mask.
var interrupt = sigset_t()
sigemptyset(&interrupt)
sigaddset(&interrupt, SIGINT)
sigaddset(&interrupt, SIGTERM)
pthread_sigmask(SIG_BLOCK, &interrupt, nil)

let launcher: Launcher
do {
  launcher = try Launcher(programs: hostedPrograms, rootJob: try Job.root())
} catch {
  fail("can't make the launcher: \(error)")
}
do {
  try launcher.start(files)
} catch {
  launcher.stop()
  fail("\(error)")
}
print(launcher.status, terminator: "")
if !check {
  var signal: Int32 = 0
  sigwait(&interrupt, &signal)
}
launcher.stop()
