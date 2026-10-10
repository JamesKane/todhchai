// SPDX-License-Identifier: BSD-3-Clause

// Sys: what services use to reach the kernel (docs/milestones/N0.md). croi's
// object model and values; the calls go to `Kernel` (lib/sys/backend), the
// hosted kernel in SwiftPM, croi's syscalls natively (M3).

@_exported import SysABI

/// A handle this process owns. It is `~Copyable`, so exactly one owner
/// holds it, and it closes when dropped. `release()` gives up ownership
/// without closing, to move the handle into a message.
@frozen public struct Handle: ~Copyable {
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

  deinit { Kernel.close(raw) }

  /// Another handle to the same object, with `rights` (at most this one's).
  public func duplicate(_ rights: Rights = .sameRights) throws(Status) -> Handle {
    Handle(raw: try Kernel.duplicate(raw, rights))
  }

  /// This handle, with fewer rights; this one is gone either way.
  public consuming func replace(_ rights: Rights) throws(Status) -> Handle {
    let raw = release()
    return Handle(raw: try Kernel.replace(raw, rights))
  }

  /// object_get_info, HANDLE_BASIC: the object's koid, type and peer.
  public func info() throws(Status) -> HandleInfo { try Kernel.info(raw) }

  public func signal(clear: UInt32 = 0, set: UInt32) throws(Status) { try Kernel.signal(raw, clear, set) }

  /// Sets and clears signals on the peer of a channel or eventpair end.
  public func signalPeer(clear: UInt32 = 0, set: UInt32) throws(Status) { try Kernel.signalPeer(raw, clear, set) }

  /// Waits until the object asserts one of `signals` or `deadline`
  /// (monotonic nanoseconds) passes; the signals observed.
  public func wait(for signals: UInt32, deadline: Int64 = infiniteDeadline) throws(Status) -> UInt32 {
    try Kernel.wait(raw, signals, deadline)
  }

  /// A packet to `port` (with `key`) when the object asserts one of
  /// `signals`, once; `edge`: only when one becomes asserted.
  public func waitAsync(port: borrowing Handle, key: UInt64, signals: UInt32, edge: Bool = false) throws(Status) {
    try Kernel.waitAsync(raw, port.raw, key, signals, edge)
  }
}

/// object_get_info's HANDLE_BASIC record.
public struct HandleInfo: Equatable, Sendable {
  public var koid: UInt64
  public var rights: Rights
  public var type: UInt32
  /// The peer's koid, for channels and eventpairs.
  public var relatedKoid: UInt64

  public init(koid: UInt64, rights: Rights, type: UInt32, relatedKoid: UInt64) {
    self.koid = koid
    self.rights = rights
    self.type = type
    self.relatedKoid = relatedKoid
  }
}

/// A pair of handles a call made (a channel's ends, an eventpair's). Take
/// them apart with `let a = ends.a`.
@frozen public struct Ends: ~Copyable {
  public var a: Handle
  public var b: Handle
}

/// Closes a raw handle nothing owns (one read from a message being dropped).
public func close(raw: UInt32) { Kernel.close(raw) }

/// Sets and clears an object's settable signals.
public func signal(_ object: borrowing Handle, clear: UInt32 = 0, set: UInt32) throws(Status) {
  try object.signal(clear: clear, set: set)
}

/// Waits until `object` asserts one of `signals` or `deadline` passes.
public func wait(_ object: borrowing Handle, for signals: UInt32, deadline: Int64 = infiniteDeadline)
  throws(Status) -> UInt32
{
  try object.wait(for: signals, deadline: deadline)
}

public enum Clock {
  /// Nanoseconds on the monotonic clock, the time base of every deadline.
  public static func monotonic() -> Int64 { Kernel.now() }

  /// Nanoseconds since the Unix epoch, for timestamps people read. Natively
  /// the monotonic clock until croi has a UTC clock (requirement 15).
  public static func realtime() -> Int64 { Kernel.realtime() }
}

/// Sleeps until `deadline`.
public func sleep(until deadline: Int64) { Kernel.sleep(deadline) }
