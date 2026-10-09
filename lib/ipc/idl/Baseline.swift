// SPDX-License-Identifier: BSD-3-Clause

// The API baseline: each method's wire signature, one line each, sorted, so
// a change shows in review as a diff. `compatibility` says whether a new
// version of a protocol still serves clients of the recorded one
// (architecture §4: a change that would break an older client fails the
// build).

import IPCModel

/// One method as the baseline records it.
public struct BaselineMethod: Equatable {
  public var name: String
  public var kind: String  // call, oneway, event
  public var since: Int
  public var parameters: [String]  // Swift types, in order
  public var result: String  // "-" for none
  public var error: String  // "-" for none

  init(_ m: Method) {
    name = m.name
    kind = switch m.kind {
    case .call: "call"
    case .oneway: "oneway"
    case .event: "event"
    }
    since = m.since
    parameters = m.parameters.map(\.swiftType)
    result = m.result?.swiftType ?? "-"
    error = m.errorType ?? "-"
  }

  init?(line: String) {
    // method NAME KIND since N params (A,B) result R throws E
    let f = line.split(separator: " ").map(String.init)
    guard f.count == 11, f[0] == "method", f[3] == "since", f[5] == "params", f[7] == "result",
      f[9] == "throws", let since = Int(f[4]), f[6].hasPrefix("("), f[6].hasSuffix(")")
    else { return nil }
    name = f[1]
    kind = f[2]
    self.since = since
    let inner = f[6].dropFirst().dropLast()
    parameters = inner.isEmpty ? [] : inner.split(separator: ",").map(String.init)
    result = f[8]
    error = f[10]
  }

  var line: String {
    "method \(name) \(kind) since \(since) params (\(parameters.joined(separator: ","))) result \(result) throws \(error)"
  }
}

/// A protocol's recorded API.
public struct Baseline: Equatable {
  public var id: String
  public var version: Int
  public var methods: [BaselineMethod]

  public init(_ p: ProtocolModel) {
    id = p.id
    version = p.version
    methods = p.methods.map(BaselineMethod.init).sorted { $0.name < $1.name }
  }

  /// The baseline file's text.
  public var text: String {
    (["# API baseline for \(id), written by idlc. Commit it; idlc checks changes against it.",
      "protocol \(id) version \(version)"] + methods.map(\.line)).joined(separator: "\n") + "\n"
  }

  public init?(text: String) {
    var id: String?
    var version: Int?
    var methods: [BaselineMethod] = []
    for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
      let f = line.split(separator: " ")
      if f.first == "protocol", f.count == 4, f[2] == "version" {
        id = String(f[1])
        version = Int(f[3])
      } else if let m = BaselineMethod(line: line) {
        methods.append(m)
      } else {
        return nil
      }
    }
    guard let id, let version else { return nil }
    self.id = id
    self.version = version
    self.methods = methods
  }
}

/// Why `new` would break a client built against `old`; empty if it wouldn't.
public func compatibility(old: Baseline, new: Baseline) -> [String] {
  var problems: [String] = []
  if new.id != old.id { problems.append("the protocol id changed from \(old.id) to \(new.id)") }
  if new.version < old.version {
    problems.append("the version went down from \(old.version) to \(new.version)")
  }
  let current = Dictionary(uniqueKeysWithValues: new.methods.map { ($0.name, $0) })
  for m in old.methods {
    guard let now = current[m.name] else {
      problems.append("'\(m.name)' was removed")
      continue
    }
    if now != m { problems.append("'\(m.name)' changed: was `\(m.line)`, now `\(now.line)`") }
  }
  let known = Set(old.methods.map(\.name))
  let added = new.methods.filter { !known.contains($0.name) }
  for m in added where m.since <= old.version {
    problems.append("'\(m.name)' is new, so it needs @since(\(old.version + 1)) or later")
  }
  if !added.isEmpty && new.version == old.version {
    problems.append("methods were added, so the version must go up from \(old.version)")
  }
  return problems
}
