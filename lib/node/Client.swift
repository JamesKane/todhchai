// SPDX-License-Identifier: BSD-3-Clause

// Conveniences for Node clients: paths, whole reads, text and listings.

import IPC

extension NodeIPC.Walked {
  /// The channel the walk ended with, if it went all the way.
  public consuming func take() -> Handle? {
    let node = self.node
    return node
  }
}

extension NodeIPC.NodeClient {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  /// A channel to the node at `path` ("a/b/c", relative to this node),
  /// walking 16 names at a time. A walk that stops early is `notFound`.
  public mutating func open(_ path: String) throws(Failure) -> NodeIPC.NodeClient {
    var names = path.split(separator: "/").map(String.init)[...]
    var client = try NodeIPC.NodeClient(walked: try walk(Array(names.prefix(NodeIPC.maxWalk))))
    names = names.dropFirst(NodeIPC.maxWalk)
    while !names.isEmpty {
      client = try NodeIPC.NodeClient(walked: try client.walk(Array(names.prefix(NodeIPC.maxWalk))))
      names = names.dropFirst(NodeIPC.maxWalk)
    }
    return client
  }

  /// A client of the node a walk (or create) ended at; `notFound` if the
  /// walk stopped early.
  public init(walked: consuming NodeIPC.Walked) throws(Failure) {
    let node = walked.node
    switch consume node {
    case .some(let h): self.init(channel: h)
    case .none: throw .remote(.notFound)
    }
  }

  /// The whole contents.
  public mutating func readAll() throws(Failure) -> [UInt8] {
    var out: [UInt8] = []
    while true {
      let chunk = try read(offset: UInt64(out.count), max: UInt32(NodeIPC.maxIO))
      out += chunk
      if chunk.count < NodeIPC.maxIO { return out }
    }
  }

  /// The contents as text (invalid UTF-8 repaired).
  public mutating func readText() throws(Failure) -> String { String(decoding: try readAll(), as: UTF8.self) }

  /// Writes `text` at offset 0: for a `ctl` leaf, one command.
  public mutating func writeText(_ text: String) throws(Failure) {
    _ = try write(offset: 0, Array(text.utf8))
  }

  /// Every entry of a directory.
  public mutating func list(fields: UInt32 = NodeIPC.Fields.all) throws(Failure) -> [NodeIPC.Stat] {
    var out: [NodeIPC.Stat] = []
    var cursor: UInt64 = 0
    while true {
      let batch = try readdir(cursor: cursor, max: 256, fields: fields)
      out += batch.entries
      if batch.done { return out }
      cursor = batch.next
    }
  }
}
