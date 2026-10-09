// SPDX-License-Identifier: BSD-3-Clause

/// What a handle allows. A handle keeps its rights when it moves through a
/// channel.
public struct Rights: OptionSet, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let transfer = Rights(rawValue: 1 << 0)
  public static let read = Rights(rawValue: 1 << 1)
  public static let write = Rights(rawValue: 1 << 2)
  public static let wait = Rights(rawValue: 1 << 3)
  public static let signal = Rights(rawValue: 1 << 4)

  public static let channelDefault: Rights = [.transfer, .read, .write, .wait, .signal]
  public static let eventDefault: Rights = [.transfer, .wait, .signal]
}

/// Signals an object can assert. Waiting is on a set of them.
public enum Signals {
  /// A channel has a message to read.
  public static let readable: UInt32 = 1 << 0
  /// A channel's peer is closed.
  public static let peerClosed: UInt32 = 1 << 2
  /// An event is signaled.
  public static let signaled: UInt32 = 1 << 3
  /// Signals with no system meaning, free for protocols to use.
  public static let user: UInt32 = 0xff00_0000
  /// The signals `signal(_:clear:set:)` may change.
  public static let settable: UInt32 = signaled | user
}

/// A deadline that never passes.
public let infiniteDeadline = Int64.max
