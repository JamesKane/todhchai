// SPDX-License-Identifier: BSD-3-Clause

// What a process the launcher starts is given: its startup handle is a
// channel on which the launcher serves Startup. The process asks it for its
// name and arguments, its namespace's mounts, the channel to serve its own
// Node tree on (if it exports one), the session board (if granted), and
// says when it is ready.

import IPC
import Node

@IPCLibrary(id: "todhchai.launch", version: 1)
public enum LaunchIPC {
  public enum StartupError: Int32, IPCErrorCode, Sendable {
    case notFound = 1
    /// Asked for twice (the export and board channels are handed out once).
    case taken
  }

  public enum Placement: UInt8, Sendable {
    case replace = 1, before, after
  }

  public struct StartInfo: Equatable, Sendable {
    public var name: String
    public var args: [String]
    public var sealed: Bool
    public var mounts: UInt32
  }

  public struct MountEntry: ~Copyable {
    public var path: String
    public var node: Handle
    public var placement: Placement
    public var create: Bool
  }

  public protocol Startup {
    func info() -> StartInfo
    func mount(_ index: UInt32) throws(StartupError) -> MountEntry
    func export() throws(StartupError) -> Handle
    func board() throws(StartupError) -> Handle
    /// The process is serving: services that use it may start.
    func ready()
  }
}

/// A started process's view of its startup: read it first thing.
///
///     let start = try Startup(handle)
///     var status = try start.namespace.open("/svc/fs/status")
///     try tree.serve(try start.export())
///     try start.ready()
public struct Startup: ~Copyable {
  public typealias Failure = IPCError<LaunchIPC.StartupError>

  public let name: String
  public let args: [String]
  /// Built from the manifest's grants, and sealed if it says so.
  public let namespace: Namespace
  var client: LaunchIPC.StartupClient

  public init(_ handle: consuming Handle) throws(Failure) {
    var client = LaunchIPC.StartupClient(channel: handle)
    let info: LaunchIPC.StartInfo
    do throws(IPCError<Never>) { info = try client.info() } catch { throw Self.lift(error) }
    let namespace = Namespace()
    for i in 0..<info.mounts {
      let entry = try client.mount(i)
      let placement: Namespace.Placement = switch entry.placement {
      case .replace: .replace
      case .before: .before
      case .after: .after
      }
      let path = entry.path, create = entry.create
      do throws(NamespaceError) {
        try namespace.mount(entry.node, at: path, placement, create: create)
      } catch {
        throw .transport(.invalidArgs)
      }
    }
    if info.sealed { namespace.seal() }
    name = info.name
    args = info.args
    self.namespace = namespace
    self.client = client
  }

  /// The channel to serve this process's Node tree on.
  public mutating func export() throws(Failure) -> Handle { try client.export() }

  /// The session's board, to post to /srv.
  public mutating func board() throws(Failure) -> SrvIPC.BoardClient {
    let channel = try client.board()
    return SrvIPC.BoardClient(channel: channel)
  }

  /// Tells the launcher this process is serving.
  public mutating func ready() throws(Failure) {
    do throws(IPCError<Never>) { try client.ready() } catch { throw Self.lift(error) }
  }

  /// A failure of a call that has no error of its own.
  static func lift(_ e: IPCError<Never>) -> Failure {
    switch e {
    case .transport(let s): .transport(s)
    case .wire(let w): .wire(w)
    }
  }
}
