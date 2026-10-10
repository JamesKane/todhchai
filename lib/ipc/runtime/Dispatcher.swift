// SPDX-License-Identifier: BSD-3-Clause

/// A generated server: what a dispatcher drives.
public protocol IPCServing: ~Copyable {
  var connection: IPCServerConnection { get }
  /// Serves one request, waiting until `deadline` for it; false once the
  /// client has closed its end.
  mutating func handleNext(deadline: Int64) throws(IPCError<Never>) -> Bool
}

import Synchronization

/// Serves many channels from one thread. A port wakes it when a channel
/// has a request (wait_async) or when another thread asks it to do
/// something for a server (`wake`, such as sending queued events), so each
/// server is only ever touched by the dispatcher's thread.
///
/// `add`, `wake` and `stop` may be called from any thread.
public final class IPCDispatcher: @unchecked Sendable {
  final class Entry: @unchecked Sendable {
    let channel: UInt32
    let serve: () throws(IPCError<Never>) -> Bool
    let wake: () throws(IPCError<Never>) -> Void

    init(channel: UInt32, serve: @escaping () throws(IPCError<Never>) -> Bool,
         wake: @escaping () throws(IPCError<Never>) -> Void) {
      self.channel = channel
      self.serve = serve
      self.wake = wake
    }
  }

  /// A server, kept where the entry's closures can reach it.
  final class Box<S: IPCServing & ~Copyable> {
    var server: S
    init(_ server: consuming S) { self.server = server }
  }

  struct Entries {
    var byID: [UInt64: Entry] = [:]
    var lastID: UInt64 = 0
  }

  let port: Handle
  let entries = Mutex(Entries())

  public init() throws(Status) { port = try Port.create() }

  /// How many channels it serves.
  public var count: Int { entries.withLock { $0.byID.count } }

  /// Serves `server`'s channel until its client closes it. `wake` runs on
  /// the dispatcher's thread for each `wake(id)`, with the server. Returns
  /// the server's id.
  @discardableResult
  public func add<S: IPCServing & ~Copyable>(
    _ server: consuming S, wake: @escaping (inout S) throws(IPCError<Never>) -> Void = { _ in }
  ) throws(Status) -> UInt64 {
    let box = Box(server)
    let entry = Entry(
      channel: box.server.connection.channel.raw,
      serve: { () throws(IPCError<Never>) -> Bool in try box.server.handleNext(deadline: 0) },
      wake: { () throws(IPCError<Never>) in try wake(&box.server) })
    let id = entries.withLock { e in
      e.lastID += 1
      e.byID[e.lastID] = entry
      return e.lastID
    }
    try arm(id, entry)
    return id
  }

  /// Asks the dispatcher to run server `id`'s wake.
  public func wake(_ id: UInt64) {
    try? Port.queue(port, Packet(key: id))
  }

  /// Makes `run` return.
  public func stop() {
    try? Port.queue(port, Packet(key: 0))
  }

  /// Serves until `stop`.
  public func run() throws(Status) {
    while true {
      let packet = try Port.wait(port)
      if packet.key == 0 && packet.type == 0 { return }
      guard let entry = entries.withLock({ $0.byID[packet.key] }) else { continue }
      var alive = true
      do throws(IPCError<Never>) {
        if packet.type == 0 {
          try entry.wake()
        } else {
          alive = try entry.serve()
        }
      } catch .transport(.timedOut) {
        // Nothing to read after all (a cancel, now answered).
      } catch {
        alive = false
      }
      if alive && packet.type != 0 {
        try arm(packet.key, entry)
      } else if !alive {
        // Dropping the server closes its channel.
        _ = entries.withLock { $0.byID.removeValue(forKey: packet.key) }
      }
    }
  }

  /// A packet when the entry's channel is readable or its peer closed.
  func arm(_ id: UInt64, _ entry: Entry) throws(Status) {
    // The server owns the channel: borrow its number, then give it back.
    let channel = Handle(raw: entry.channel)
    var failure: Status?
    do throws(Status) {
      try channel.waitAsync(port: port, key: id, signals: Signals.readable | Signals.peerClosed)
    } catch {
      failure = error
    }
    _ = channel.release()
    if let failure { throw failure }
  }
}
