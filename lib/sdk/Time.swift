// SPDX-License-Identifier: BSD-3-Clause

// Time (sdk.md §1): the monotonic clock, absolute deadlines, and sleeping
// until one. Time is absolute (principle 3): every wait takes a deadline
// and a leeway, never a relative timeout or a global resolution.

import Glibc
import TDLinux

/// A point on the monotonic clock, in nanoseconds.
public struct Deadline: Comparable, Hashable, Sendable {
  public var ns: UInt64

  public init(ns: UInt64) { self.ns = ns }

  /// Now, on the monotonic clock (the vDSO; no system call).
  public static var now: Deadline {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Deadline(ns: UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec))
  }

  public static func < (a: Deadline, b: Deadline) -> Bool { a.ns < b.ns }

  public static func + (d: Deadline, by: Duration) -> Deadline { Deadline(ns: d.ns &+ by.nanoseconds) }

  /// The time from `earlier` to this deadline (zero if it is earlier).
  public func since(_ earlier: Deadline) -> Duration { .nanoseconds(Int64(ns > earlier.ns ? ns - earlier.ns : 0)) }

  var asTimespec: timespec { timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000)) }
}

extension Duration {
  /// The duration in whole nanoseconds, saturating at zero.
  public var nanoseconds: UInt64 {
    let (seconds, attoseconds) = components
    guard seconds >= 0 else { return 0 }
    return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
  }
}

/// Sleeps until `deadline`. The kernel may wake the thread up to `leeway`
/// late, which lets it coalesce wakeups (Linux's per-thread timer slack).
public func sleep(until deadline: Deadline, leeway: Duration = .zero) {
  setTimerSlack(leeway)
  var ts = deadline.asTimespec
  while clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nil) == EINTR {}
}

/// Sets the calling thread's timer slack, at least 1 ns.
func setTimerSlack(_ leeway: Duration) {
  _ = td_linux_set_timer_slack(leeway.nanoseconds)
}
