// SPDX-License-Identifier: BSD-3-Clause

/// A handle this process owns. It is `~Copyable`, so exactly one owner
/// holds it, and it closes when dropped. `release()` gives up ownership
/// without closing, to move the handle into a message.
public struct Handle: ~Copyable {
  public let raw: UInt32

  /// Takes ownership of a raw handle, such as one read from a message.
  public init(raw: UInt32) { self.raw = raw }

  /// Gives up ownership: the handle stays open, and the caller is now
  /// responsible for it (usually by writing it into a message).
  public consuming func release() -> UInt32 {
    let raw = self.raw
    discard self
    return raw
  }

  deinit { try? HostKernel.shared.close(raw) }
}

/// A channel: two endpoints, each a handle.
public enum Channel {
  /// A new channel's two ends. Take them apart with `let a = ends.a`.
  @frozen public struct Ends: ~Copyable {
    public var a: Handle
    public var b: Handle
  }

  /// A new channel.
  public static func create() throws(Status) -> Ends {
    let (a, b) = try HostKernel.shared.channelCreate()
    return Ends(a: Handle(raw: a), b: Handle(raw: b))
  }

  /// Writes a message, moving `handles` into it (they are consumed even on
  /// failure).
  public static func write(_ channel: borrowing Handle, bytes: [UInt8], handles: [UInt32] = [])
    throws(Status)
  {
    try HostKernel.shared.channelWrite(channel.raw, bytes: bytes, handles: handles)
  }

  /// A message read from a channel; its handles are now this process's.
  public struct Message {
    public var bytes: [UInt8]
    public var handles: [UInt32]
  }

  /// Reads the next message, or throws `shouldWait` if there is none.
  public static func read(_ channel: borrowing Handle) throws(Status) -> Message {
    let raw = channel.raw
    var bytes = [UInt8](repeating: 0, count: 65_536)
    var handles = [UInt32](repeating: 0, count: 64)
    do {
      // Untyped closures: a `throws(E)` closure passed to these `rethrows`
      // methods miscompiles in Swift 6.4 (CLAUDE.md, "Toolchain pitfalls").
      let got = try bytes.withUnsafeMutableBytes { b in
        try handles.withUnsafeMutableBufferPointer { h in
          try HostKernel.shared.channelRead(raw, bytes: b, handles: h)
        }
      }
      return Message(bytes: Array(bytes[..<got.byteCount]), handles: Array(handles[..<got.handleCount]))
    } catch {
      throw (error as? HostKernel.ReadError)?.status ?? .invalidArgs
    }
  }
}

/// An event: an object with a signal anyone holding it may set or clear.
public enum Event {
  public static func create() throws(Status) -> Handle {
    Handle(raw: try HostKernel.shared.eventCreate())
  }
}

/// Sets and clears an object's settable signals.
public func signal(_ object: borrowing Handle, clear: UInt32 = 0, set: UInt32) throws(Status) {
  try HostKernel.shared.signal(object.raw, clear: clear, set: set)
}

/// Waits until `object` asserts one of `signals` or `deadline` (monotonic
/// nanoseconds) passes, and returns the signals observed.
public func wait(_ object: borrowing Handle, for signals: UInt32, deadline: Int64 = infiniteDeadline)
  throws(Status) -> UInt32
{
  do {
    return try HostKernel.shared.wait(object.raw, for: signals, deadline: deadline)
  } catch {
    throw error.status
  }
}
