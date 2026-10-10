// SPDX-License-Identifier: BSD-3-Clause

// The Node protocol (architecture §6): every service is a browsable tree.
// A channel to a node is like a 9P fid; walking from it hands out a channel
// to the node reached. Shaped like 9P, but channels already give what 9P's
// fids, tags, version and attach exist for.

import IPC

@IPCLibrary(id: "todhchai.node", version: 1)
public enum NodeIPC {
  public enum NodeError: Int32, IPCErrorCode, Sendable {
    case notFound = 1
    case notDirectory
    case isDirectory
    case exists
    case denied
    /// A name that is empty, ".", longer than 255 bytes, or holds "/" or NUL.
    case badName
    /// More than 16 names in one walk.
    case tooManyNames
    case notEmpty
    /// The node doesn't do that (writing a read-only leaf, creating in a
    /// directory that doesn't allow it).
    case unsupported
    /// What was written isn't valid for the node (a ctl leaf's command).
    case invalid
    case io
  }

  public enum NodeKind: UInt8, Sendable {
    case file = 1
    case directory
  }

  /// A node's identity: `path` is unique in its tree and never reused;
  /// `version` changes when its contents do. For cache validation.
  public struct Qid: Equatable, Sendable {
    public var path: UInt64
    public var version: UInt32
    public var kind: NodeKind
  }

  /// A typed attribute, Taisce's way: `kind` is Taisce's AttributeKind
  /// (string 1, int64, uint64, double, time, bool, bytes, ref, type), and
  /// `value` its encoding (integers little-endian).
  public struct Attribute: Equatable, Sendable {
    public var name: String
    public var kind: UInt8
    public var value: [UInt8]
  }

  /// What stat and readdir report. Fields not asked for are zero or empty.
  public struct Stat: Equatable, Sendable {
    public var qid: Qid
    public var name: String
    public var size: UInt64
    /// Nanoseconds since the Unix epoch; 0 if unknown.
    public var modified: Int64
    public var attributes: [Attribute]
  }

  public struct DirBatch: Equatable, Sendable {
    public var entries: [Stat]
    /// The cursor to continue from.
    public var next: UInt64
    public var done: Bool
  }

  /// A walk's result: a qid for each name walked, and a channel to the last
  /// node if every name was walked (none if the walk stopped early).
  public struct Walked: ~Copyable {
    public var qids: [Qid]
    public var node: Handle?
  }

  public enum ChangeKind: UInt8, Sendable {
    case created = 1
    case removed
    case modified
    /// Changes were missed: look again.
    case overflow
  }

  /// A change to a watched node: to a directory's entry `name`, or to the
  /// file itself.
  public struct Change: Equatable, Sendable {
    public var seq: UInt64
    public var kind: ChangeKind
    public var name: String
  }

  public protocol Node {
    /// Walks at most 16 names ("..": the parent). The first failing is an
    /// error; a later one ends the walk early. No names: a clone.
    func walk(_ names: [String]) throws(NodeError) -> Walked
    func stat(_ fields: UInt32) throws(NodeError) -> Stat
    func readdir(cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> DirBatch
    func read(offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8]
    func write(offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32
    /// Sends `changed` events for this node from now on, first replaying
    /// those after `seq` (0: none). Returns the current sequence number.
    func watch(since seq: UInt64) throws(NodeError) -> UInt64
    @event func changed(_ change: Change)
    func create(_ name: String, kind: NodeKind) throws(NodeError) -> Walked
    func remove() throws(NodeError)
  }
}

extension NodeIPC {
  /// What stat and readdir fill in beyond the qid and name.
  public enum Fields {
    public static let size: UInt32 = 1 << 0
    public static let modified: UInt32 = 1 << 1
    public static let attributes: UInt32 = 1 << 2
    public static let all: UInt32 = 0b111
  }

  /// The most names one walk takes.
  public static let maxWalk = 16
  /// The most bytes one read or write moves.
  public static let maxIO = 32_768

  /// Whether `name` may name a node.
  public static func isValidName(_ name: String) -> Bool {
    let utf8 = name.utf8
    return !utf8.isEmpty && utf8.count <= 255 && name != "." && !utf8.contains(0x2F) && !utf8.contains(0)
  }
}
