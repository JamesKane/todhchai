// SPDX-License-Identifier: BSD-3-Clause

// td trace: records and reads traces (docs/trace-format.md).
//
//   td trace record -o DIR [-c CATEGORIES] [--circular] -- PROGRAM [ARGS]
//   td trace print FILE...           every record, merged by time
//   td trace summary FILE...         zones per name: count, total, p50, p99, max
//   td trace diff A B                summaries side by side, B against A

import Bench
import FoundationEssentials
import Glibc
import TraceFormat
import TraceReader

func readTrace(_ path: String) -> TraceFile {
  guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
  do {
    return try TraceFile(bytes: [UInt8](data))
  } catch {
    fail("\(path): \(error)")
  }
}

/// Every trace file named, a directory standing for the .trace files in it.
func traceFiles(_ paths: [String]) -> [String] {
  paths.flatMap { path -> [String] in
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [path] }
    return names.filter { $0.hasSuffix(".trace") }.sorted().map { "\(path)/\($0)" }
  }
}

func traceCommand(_ args: [String]) -> Bool {
  guard let sub = args.first else { fail("usage: td trace record|print|summary|diff ...") }
  let rest = Array(args.dropFirst())
  switch sub {
  case "record": return traceRecord(rest)
  case "print":
    for path in traceFiles(rest) {
      let t = readTrace(path)
      say("# \(path): process \(t.processID), \(t.records.count) records, \(t.dropped) dropped")
      for r in t.records {
        let at = formatValue(t.seconds(r.time &- t.start))
        let what: String = switch TraceKind(rawValue: r.kind) {
        case .zone?: "zone \(t.name(r.b)) \(formatValue(t.seconds(r.a &- r.time)))"
        case .mark?: "mark \(TraceFile.label(r))"
        case .flow?: "flow \(t.name(r.b)) id \(r.a)"
        case .counter?: "counter \(t.name(r.a)) = \(Int64(bitPattern: r.b))"
        case nil: "kind 0x\(String(r.kind, radix: 16)) a \(r.a) b \(r.b)"
        }
        say("\(at)\tthread \(r.tid)\t\(what)")
      }
    }
    return true
  case "summary":
    for path in traceFiles(rest) { say(summary(readTrace(path), title: path)) }
    return true
  case "diff":
    guard rest.count == 2 else { fail("td trace diff A B") }
    let a = readTrace(rest[0]).zones(), b = readTrace(rest[1]).zones()
    var out = "| Zone | A p50 | B p50 | A p99 | B p99 | p99 change |\n|---|---:|---:|---:|---:|---:|\n"
    for name in Set(a.keys).union(b.keys).sorted() {
      let da = Distribution(a[name] ?? []), db = Distribution(b[name] ?? [])
      let change = da.p99 > 0 ? "\(Int(((db.p99 - da.p99) / da.p99 * 100).rounded()))%" : "—"
      out += "| `\(name)` | \(formatValue(da.p50)) | \(formatValue(db.p50)) | \(formatValue(da.p99)) | \(formatValue(db.p99)) | \(change) |\n"
    }
    say(out)
    return true
  default:
    fail("unknown trace command \(sub)")
  }
}

func summary(_ t: TraceFile, title: String) -> String {
  var out = "# \(title)\n\n| Zone | Count | Total | p50 | p99 | Max |\n|---|---:|---:|---:|---:|---:|\n"
  for (name, durations) in t.zones().sorted(by: { $0.key < $1.key }) {
    let d = Distribution(durations)
    out += "| `\(name)` | \(d.count) | \(formatValue(d.total)) | \(formatValue(d.p50)) | \(formatValue(d.p99)) | \(formatValue(d.max)) |\n"
  }
  let flows = t.flows()
  if !flows.isEmpty {
    // A flow's span is its first step to its last: for an IPC call, the
    // call's write to its reply's read.
    out += "\n| Flow | Count | Steps | p50 | p99 | Max |\n|---|---:|---:|---:|---:|---:|\n"
    for (name, spans) in flows.sorted(by: { $0.key < $1.key }) {
      let d = Distribution(spans.map(\.seconds))
      let steps = Set(spans.map(\.steps)).sorted().map(String.init).joined(separator: ", ")
      out += "| `\(name)` | \(d.count) | \(steps) | \(formatValue(d.p50)) | \(formatValue(d.p99)) | \(formatValue(d.max)) |\n"
    }
  }
  if t.dropped > 0 { out += "\n\(t.dropped) records dropped: the rings were full.\n" }
  return out
}

func traceRecord(_ args: [String]) -> Bool {
  var dir: String?
  var categories = "app,frame,audio,input,ipc,io,mark"
  var circular = false
  var i = 0
  while i < args.count, args[i] != "--" {
    switch args[i] {
    case "-o": i += 1; dir = i < args.count ? args[i] : nil
    case "-c": i += 1; categories = i < args.count ? args[i] : ""
    case "--circular": circular = true
    default: fail("unknown option \(args[i])")
    }
    i += 1
  }
  guard let dir else { fail("td trace record needs -o DIR") }
  guard TraceCategory(names: categories) != nil else { fail("unknown categories in \(categories)") }
  let program = Array(args.dropFirst(i + 1))
  guard !program.isEmpty else { fail("td trace record ... -- PROGRAM [ARGS]") }
  makeDirectory(dir)
  setenv("TODHCHAI_TRACE", dir, 1)
  setenv("TODHCHAI_TRACE_CATEGORIES", categories, 1)
  if circular { setenv("TODHCHAI_TRACE_CIRCULAR", "1", 1) }
  let r = run(program, log: nil)
  say("td trace: \(program[0]) \(r.ok ? "exited 0" : "failed"); traces in \(dir)")
  return r.ok
}
