// SPDX-License-Identifier: BSD-3-Clause

// Events (sdk.md §2): fixed-size records the loop hands out. M1b has the
// loop's own sources; window, frame, input and audio events join with
// their steps. The C ABI's 80-byte layout comes with M1g.

/// A window, as an index plus a generation (principle 12). Zero for events
/// that don't belong to one.
public struct WindowID: Hashable, Sendable {
  public var index: UInt32
  public var generation: UInt32
  public static let none = WindowID(index: 0, generation: 0)
}

/// A timer the loop owns.
public struct TimerID: Hashable, Sendable { public var raw: UInt64 }

/// A file descriptor the loop watches.
public struct WatchID: Hashable, Sendable { public var raw: UInt64 }

/// Two words posted to a loop, from any thread.
public struct Message: Hashable, Sendable {
  public var a: UInt64
  public var b: UInt64
  public init(_ a: UInt64, _ b: UInt64 = 0) {
    self.a = a
    self.b = b
  }
}

/// Readiness of a watched file descriptor.
public struct Readiness: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let readable = Readiness(rawValue: 1 << 0)
  public static let writable = Readiness(rawValue: 1 << 1)
  public static let hangup = Readiness(rawValue: 1 << 2)
  public static let error = Readiness(rawValue: 1 << 3)
}

public struct Event: Sendable {
  public enum Payload: Sendable, Equatable {
    /// A timer's deadline came. `missed` counts repeats skipped because
    /// the loop was late.
    case timer(TimerID, missed: UInt64)
    /// A watched file descriptor is ready.
    case watch(WatchID, Readiness)
    /// A message posted to the loop.
    case message(Message)
    /// The loop was woken (wakes are coalesced: one event for many).
    case wake
    /// The process was asked to stop (SIGINT, SIGTERM).
    case quit
    /// A window's size, scale or state changed; draw for this `configSeq`.
    case configure(Configure)
    /// The user asked to close a window.
    case close
    /// Time to draw a window's next frame.
    case frame(Frame)
    /// A key went down, or repeats while held.
    case keyDown(Key)
    case keyUp(Key)
    /// The pointer entered, left, moved, or a button changed.
    case pointer(Pointer)
    /// The wheel or a touchpad scrolled.
    case wheel(Wheel)
  }

  public var payload: Payload
  public var window: WindowID
  /// When the event was taken, on the monotonic clock.
  public var time: Deadline
  /// The event's place in this loop's sequence, from 1.
  public var seq: UInt64
}

/// The events one `wait` returned: valid until the next one. Holding them
/// longer is safe but makes the next wait copy its buffer. Within a batch,
/// `.frame` events come last, so a frame is drawn for the newest
/// configuration.
public struct Events: RandomAccessCollection, Sendable {
  let items: [Event]
  public var startIndex: Int { items.startIndex }
  public var endIndex: Int { items.endIndex }
  public subscript(i: Int) -> Event { items[i] }
}
