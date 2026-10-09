// SPDX-License-Identifier: BSD-3-Clause

// idlc: reads Swift files that declare @IPCProtocol protocols and writes, for
// each protocol, a C header, a Markdown reference page, and an API baseline
// checked against the recorded one (architecture §4).
//
//   idlc [--c-out DIR] [--doc-out DIR] [--baseline DIR [--update-baseline]] FILE...
//
// Exits 1 if a protocol can't be read or breaks its baseline.

// FoundationEssentials only, as principle 29 allows for tier 1.
import FoundationEssentials
import Glibc
import IDL

func complain(_ message: String) {
  let line = Array("idlc: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}

func fail(_ message: String) -> Never {
  complain(message)
  exit(1)
}

/// `value`, or exit with `message` if there is none.
func need(_ value: String?, _ message: String) -> String {
  guard let value else { fail(message) }
  return value
}

func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

var cOut: String?
var docOut: String?
var baselineDir: String?
var updateBaseline = false
var files: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
  switch arg {
  case "--c-out": cOut = need(args.popFirst(), "--c-out needs a directory")
  case "--doc-out": docOut = need(args.popFirst(), "--doc-out needs a directory")
  case "--baseline": baselineDir = need(args.popFirst(), "--baseline needs a directory")
  case "--update-baseline": updateBaseline = true
  default:
    if arg.hasPrefix("-") { fail("unknown option \(arg)") }
    files.append(arg)
  }
}
if files.isEmpty { fail("no input files") }

let sources = files.map { path in
  (path: path, text: need(try? String(contentsOfFile: path, encoding: .utf8), "can't read \(path)"))
}
let interface: Interface
do {
  interface = try scan(sources)
} catch {
  fail(error.description)
}
if interface.protocols.isEmpty { fail("no @IPCProtocol protocols in \(files.joined(separator: ", "))") }

func save(_ text: String, to dir: String, _ name: String) {
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let path = join(dir, name)
  do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("can't write \(path)") }
}

var broken = false
let source = files.count == 1 ? files[0] : "\(files.count) files"
for p in interface.protocols {
  if let cOut { save(cHeader(p, errors: interface.errors, source: source), to: cOut, "\(snakeName(p)).h") }
  if let docOut { save(markdown(p, errors: interface.errors, source: source), to: docOut, "\(p.name).md") }
  if let baselineDir {
    let path = join(baselineDir, "\(p.id).api")
    let new = Baseline(p)
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
      guard let old = Baseline(text: text) else { fail("\(path) is not a baseline") }
      let problems = compatibility(old: old, new: new)
      for problem in problems {
        complain("\(p.id): \(problem)")
      }
      broken = broken || !problems.isEmpty
      if problems.isEmpty && updateBaseline { save(new.text, to: baselineDir, "\(p.id).api") }
    } else if updateBaseline {
      save(new.text, to: baselineDir, "\(p.id).api")
    } else {
      fail("\(p.id) has no baseline at \(path); run with --update-baseline to record one")
    }
  }
}
if broken { exit(1) }
