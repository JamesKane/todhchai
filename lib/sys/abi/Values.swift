// SPDX-License-Identifier: BSD-3-Clause

// croi's ABI values, which are Zircon's (croi's syscall.h, ipc.h, task.h):
// statuses, rights, signals, object types and port packets. Shared by the
// hosted kernel (SysHost) and the typed API (Sys), so both speak croi's
// numbers.

/// A system call's result: Zircon's values, negative, so they can travel
/// in an epitaph.
public enum Status: Int32, Error, Equatable, Sendable {
  case ok = 0
  case `internal` = -1
  case notSupported = -2
  case noResources = -3
  case noMemory = -4
  case invalidArgs = -10
  case badHandle = -11
  case wrongType = -12
  case badSyscall = -13
  case outOfRange = -14
  case bufferTooSmall = -15
  case badState = -20
  case timedOut = -21
  case shouldWait = -22
  case canceled = -23
  case peerClosed = -24
  case notFound = -25
  case alreadyExists = -26
  case alreadyBound = -27
  case unavailable = -28
  case accessDenied = -30
}

/// What a handle allows (Zircon's ZX_RIGHT_*). A handle keeps its rights
/// when it moves through a channel.
public struct Rights: OptionSet, Equatable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let duplicate = Rights(rawValue: 1 << 0)
  public static let transfer = Rights(rawValue: 1 << 1)
  public static let read = Rights(rawValue: 1 << 2)
  public static let write = Rights(rawValue: 1 << 3)
  public static let execute = Rights(rawValue: 1 << 4)
  public static let map = Rights(rawValue: 1 << 5)
  public static let getProperty = Rights(rawValue: 1 << 6)
  public static let setProperty = Rights(rawValue: 1 << 7)
  public static let enumerate = Rights(rawValue: 1 << 8)
  public static let destroy = Rights(rawValue: 1 << 9)
  public static let getPolicy = Rights(rawValue: 1 << 10)
  public static let setPolicy = Rights(rawValue: 1 << 11)
  public static let signal = Rights(rawValue: 1 << 12)
  public static let signalPeer = Rights(rawValue: 1 << 13)
  public static let wait = Rights(rawValue: 1 << 14)
  public static let inspect = Rights(rawValue: 1 << 15)
  public static let manageJob = Rights(rawValue: 1 << 16)
  public static let manageProcess = Rights(rawValue: 1 << 17)
  public static let manageThread = Rights(rawValue: 1 << 18)
  public static let applyProfile = Rights(rawValue: 1 << 19)
  public static let manageVmo = Rights(rawValue: 1 << 24)
  /// handle_duplicate and handle_replace: the same rights as the source.
  public static let sameRights = Rights(rawValue: 1 << 31)

  static let basic: Rights = [.transfer, .duplicate, .wait, .inspect]
  static let io: Rights = [.read, .write]
  static let property: Rights = [.getProperty, .setProperty]
  static let policy: Rights = [.getPolicy, .setPolicy]

  public static let channelDefault: Rights = [.transfer, .wait, .inspect, .read, .write, .signal, .signalPeer]
  public static let eventDefault: Rights = basic.union(.signal)
  public static let eventPairDefault: Rights = basic.union([.signal, .signalPeer])
  public static let portDefault: Rights = [.transfer, .duplicate, .inspect, .read, .write]
  public static let vmoDefault: Rights = basic.union(io).union(property).union([.map, .signal])
  public static let timerDefault: Rights = basic.union([.write, .signal])
  public static let jobDefault: Rights = basic.union(io).union(property).union(policy)
    .union([.enumerate, .destroy, .signal, .manageJob, .manageProcess, .manageThread])
  public static let processDefault: Rights = basic.union(io).union(property)
    .union([.enumerate, .destroy, .signal, .manageProcess, .manageThread])
  public static let threadDefault: Rights = basic.union(io).union(property).union([.destroy, .signal, .manageThread])
}

/// Signals objects assert (Zircon's ZX_*_SIGNALED and the like).
public enum Signals {
  /// A channel has a message to read.
  public static let readable: UInt32 = 1 << 0
  /// A channel can be written.
  public static let writable: UInt32 = 1 << 1
  /// A channel's or eventpair's peer is closed.
  public static let peerClosed: UInt32 = 1 << 2
  /// An event, eventpair or timer is signaled.
  public static let signaled: UInt32 = 1 << 3
  /// A job, process or thread has ended (the same bit).
  public static let terminated: UInt32 = 1 << 3
  /// A thread is running.
  public static let threadRunning: UInt32 = 1 << 4
  /// Eight signals with no system meaning, free for protocols.
  public static let user: UInt32 = 0xFF00_0000
}

/// Object types, as object_get_info reports them.
public enum ObjectType {
  public static let process: UInt32 = 1
  public static let thread: UInt32 = 2
  public static let vmo: UInt32 = 3
  public static let channel: UInt32 = 4
  public static let event: UInt32 = 5
  public static let port: UInt32 = 6
  public static let log: UInt32 = 12
  public static let resource: UInt32 = 15
  public static let eventPair: UInt32 = 16
  public static let job: UInt32 = 17
  public static let vmar: UInt32 = 18
  public static let timer: UInt32 = 22
  public static let profile: UInt32 = 25
  public static let exception: UInt32 = 29
}

/// A port packet (zx_port_packet_t): key, type, status and 32 bytes.
public struct Packet: Equatable, Sendable {
  public var key: UInt64
  /// 0: queued by a user; 1: a signal (wait_async).
  public var type: UInt32
  public var status: Int32
  /// Signal packets: trigger | observed << 32, count, timestamp, 0.
  public var payload: (UInt64, UInt64, UInt64, UInt64)

  public init(key: UInt64, type: UInt32 = 0, status: Int32 = 0, payload: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)) {
    self.key = key
    self.type = type
    self.status = status
    self.payload = payload
  }

  public static func == (a: Packet, b: Packet) -> Bool {
    a.key == b.key && a.type == b.type && a.status == b.status && a.payload.0 == b.payload.0
      && a.payload.1 == b.payload.1 && a.payload.2 == b.payload.2 && a.payload.3 == b.payload.3
  }

  /// For a signal packet: the signals that triggered it, and all observed.
  public var trigger: UInt32 { UInt32(truncatingIfNeeded: payload.0) }
  public var observed: UInt32 { UInt32(truncatingIfNeeded: payload.0 >> 32) }
}

/// A deadline that never passes.
public let infiniteDeadline = Int64.max

/// The flow id of a channel message (croi's croi_flow_id, ipc.h): both ends
/// compute it from what they share, the channel's id (the smaller of its
/// two endpoints' koids) and the message's txid, so a call and its reply
/// share one flow and nothing extra travels. splitmix64's finalizer.
public func flowID(channel: UInt64, txid: UInt32) -> UInt64 {
  var z = channel &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(txid)
  z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
  z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
  return z ^ (z >> 31)
}
