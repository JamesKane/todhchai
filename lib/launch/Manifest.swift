// SPDX-License-Identifier: BSD-3-Clause

// Launcher manifests (architecture §3, §5): line-based text in the style of
// Plan 9's namespace files. One directive a line; `#` starts a comment.
//
//     service fs              # first: the service's name
//     program fs              # what runs (hosted: a registered program)
//     arg --cache 64          # arguments, in order
//     export                  # it serves a Node tree others may use
//     use block               # granted at /svc/block
//     mount /data fs/data/me after create   # PATH SERVICE[/SUB] [before|after] [create]
//     srv                     # the session board, at /srv
//     seal                    # its namespace is sealed
//     restart on-failure      # never (the default), on-failure or always
//     resource mmio           # a kind of hardware: mmio, irq, ioport, smc or system
//     programs                # it starts programs from bootfs, in a job under its own
//
// `resource` and `programs` are what devmgr is given (M3g): the launcher's
// own ranged root resource of the kind, and bootfs with a job, so that it
// can start driver hosts. A launcher that has none to give refuses them.
//
// Anything wrong stops the launch with its file and line: Plan 9 ignores
// errors in namespace files, and sandboxes come out quietly wrong.

import Node
import Sys

/// A manifest error, with where it is.
public struct LaunchError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public enum RestartPolicy: String, Sendable {
  case never
  case onFailure = "on-failure"
  case always
}

public struct Manifest: Sendable {
  /// A grant of a service's tree: `use` (at /svc/NAME, reconnected after a
  /// restart) or `mount` (anywhere, a direct channel).
  public struct Grant: Sendable {
    public var path: String
    public var service: String
    public var subpath: [String]
    public var placement: LaunchIPC.Placement
    public var create: Bool
    /// `use`: through the process's /svc.
    public var viaSvc: Bool
    public var line: Int
  }

  public var file: String
  public var service = ""
  public var program = ""
  public var programLine = 0
  public var args: [String] = []
  public var exports = false
  public var grants: [Grant] = []
  public var srv = false
  public var sealed = false
  public var restart = RestartPolicy.never
  /// `resource` lines: the kinds of hardware granted.
  public var resources: [(kind: ResourceKind, line: Int)] = []
  /// `programs`: its line, or 0.
  public var programsLine = 0
  public var serviceLine = 0

  /// "file:line: message"
  func error(_ line: Int, _ message: String) -> LaunchError { LaunchError("\(file):\(line): \(message)") }

  public init(file: String, text: String) throws(LaunchError) {
    self.file = file
    var lineNumber = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      lineNumber += 1
      let content = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      let words = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard let directive = words.first else { continue }
      let rest = Array(words.dropFirst())
      if service.isEmpty && directive != "service" { throw error(lineNumber, "'service' must come first") }
      func count(_ n: ClosedRange<Int>) throws(LaunchError) {
        guard n.contains(rest.count) else {
          let expected = n.lowerBound == n.upperBound ? "\(n.lowerBound)" : "\(n.lowerBound) to \(n.upperBound)"
          throw error(lineNumber, "'\(directive)' takes \(expected) argument\(n.upperBound == 1 ? "" : "s")")
        }
      }
      switch directive {
      case "service":
        guard service.isEmpty else { throw error(lineNumber, "a second 'service'") }
        try count(1...1)
        guard NodeIPC.isValidName(rest[0]) else { throw error(lineNumber, "bad service name '\(rest[0])'") }
        service = rest[0]
        serviceLine = lineNumber
      case "program":
        try count(1...1)
        program = rest[0]
        programLine = lineNumber
      case "arg":
        args += rest
      case "export":
        try count(0...0)
        exports = true
      case "use":
        try count(1...1)
        guard NodeIPC.isValidName(rest[0]) else { throw error(lineNumber, "bad service name '\(rest[0])'") }
        grants.append(Grant(path: "/svc/\(rest[0])", service: rest[0], subpath: [], placement: .replace,
                            create: false, viaSvc: true, line: lineNumber))
      case "mount":
        try count(2...4)
        do throws(NamespaceError) { _ = try Namespace.clean(rest[0]) } catch {
          throw self.error(lineNumber, "bad path '\(rest[0])'")
        }
        let target = rest[1].split(separator: "/").map(String.init)
        guard let name = target.first, target.allSatisfy(NodeIPC.isValidName) else {
          throw error(lineNumber, "bad service path '\(rest[1])'")
        }
        var grant = Grant(path: rest[0], service: name, subpath: Array(target.dropFirst()), placement: .replace,
                          create: false, viaSvc: false, line: lineNumber)
        for option in rest.dropFirst(2) {
          switch option {
          case "before": grant.placement = .before
          case "after": grant.placement = .after
          case "create": grant.create = true
          default: throw error(lineNumber, "unknown mount option '\(option)'")
          }
        }
        grants.append(grant)
      case "srv":
        try count(0...0)
        srv = true
      case "seal":
        try count(0...0)
        sealed = true
      case "restart":
        try count(1...1)
        guard let policy = RestartPolicy(rawValue: rest[0]) else {
          throw error(lineNumber, "'restart' takes never, on-failure or always")
        }
        restart = policy
      case "resource":
        try count(1...1)
        guard let kind = ResourceKind(name: rest[0]) else {
          throw error(lineNumber, "'resource' takes mmio, irq, ioport, smc or system")
        }
        guard !resources.contains(where: { $0.kind == kind }) else { throw error(lineNumber, "a second 'resource \(rest[0])'") }
        resources.append((kind, lineNumber))
      case "programs":
        try count(0...0)
        programsLine = lineNumber
      default:
        throw error(lineNumber, "unknown directive '\(directive)'")
      }
    }
    guard !service.isEmpty else { throw LaunchError("\(file): no 'service'") }
    guard !program.isEmpty else { throw LaunchError("\(file): no 'program'") }
  }
}

/// Checks a set of manifests against each other and the programs there
/// are: every service named exists and exports, no name is taken twice,
/// nothing depends on itself. The order to start them in.
public func launchOrder(_ manifests: [Manifest], programs: [String]) throws(LaunchError) -> [Manifest] {
  for (i, m) in manifests.enumerated() {
    if let other = manifests[..<i].first(where: { $0.service == m.service }) {
      throw m.error(m.serviceLine, "service '\(m.service)' is also defined at \(other.file):\(other.serviceLine)")
    }
    guard programs.contains(m.program) else { throw m.error(m.programLine, "no program '\(m.program)'") }
    for g in m.grants {
      guard let target = manifests.first(where: { $0.service == g.service }) else {
        throw m.error(g.line, "no service '\(g.service)'")
      }
      guard target.exports else { throw m.error(g.line, "service '\(g.service)' exports nothing") }
    }
  }
  var order: [Manifest] = []
  func visit(_ m: Manifest, _ path: [String]) throws(LaunchError) {
    if order.contains(where: { $0.service == m.service }) { return }
    if let start = path.firstIndex(of: m.service) {
      let cycle = (path[start...] + [m.service]).joined(separator: " → ")
      throw m.error(m.serviceLine, "services depend on each other: \(cycle)")
    }
    for g in m.grants where g.service != m.service {
      try visit(manifests.first { $0.service == g.service }!, path + [m.service])
    }
    if m.grants.contains(where: { $0.service == m.service }) {
      throw m.error(m.serviceLine, "services depend on each other: \(m.service) → \(m.service)")
    }
    order.append(m)
  }
  for m in manifests { try visit(m, []) }
  return order
}
