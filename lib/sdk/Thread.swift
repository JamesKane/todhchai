// SPDX-License-Identifier: BSD-3-Clause

// Threads (sdk.md §8): created with an intent, never a priority
// (principle 5). A real-time intent goes through admission, which grants
// it or says why not.
//
// Hosted on Linux, intents map to scheduling policies. Linux can't promise
// what croi's EDF admission will, so the admission says what was granted:
// SCHED_DEADLINE (needs privilege), else SCHED_FIFO (needs RLIMIT_RTPRIO),
// else the normal scheduler, with the reason.

import Glibc
import TDLinux

/// What a thread is for (architecture §8).
public enum Intent: Sendable, Equatable {
  /// Periodic work with a deadline: audio callbacks, the compositor latch.
  case realtime(period: Duration, budget: Duration, deadline: Duration)
  /// Follows the frame clock: a game's main or render thread.
  case frame
  /// UI threads.
  case interactive
  /// Job systems, compilers.
  case throughput
  /// Indexers, sync: may be delayed.
  case background
}

/// What a real-time request was granted.
public enum Admission: Sendable, Equatable {
  /// No admission needed (not a real-time intent).
  case notRealtime
  /// Granted as asked: a deadline scheduler with this period and budget.
  case deadline
  /// Granted a fixed real-time priority, without a budget.
  case fixedPriority
  /// Refused: the thread runs on the normal scheduler.
  case refused(Refusal)
}

/// Why a real-time request was refused.
public enum Refusal: Sendable, Equatable, CustomStringConvertible {
  /// The host refused every real-time policy (hosted: Linux without
  /// CAP_SYS_NICE for SCHED_DEADLINE, and RLIMIT_RTPRIO 0 for SCHED_FIFO).
  case noRealtimePrivilege

  public var description: String {
    switch self {
    case .noRealtimePrivilege: "the host allows no real-time scheduling (SCHED_DEADLINE and SCHED_FIFO refused)"
    }
  }
}

public enum ThreadError: Error, Equatable {
  case system(Int32)
}

/// A thread, joined when you're done with it.
public struct Thread: ~Copyable {
  let handle: pthread_t
  /// What the intent was granted.
  public let admission: Admission

  /// Starts `body` on a new thread with `intent`.
  public static func spawn(intent: Intent, name: String? = nil, _ body: @escaping @Sendable () -> Void)
    throws(ThreadError) -> Thread
  {
    final class Start: @unchecked Sendable {
      let body: @Sendable () -> Void
      let intent: Intent
      let name: String?
      var admission = Admission.notRealtime
      var ready = pthread_mutex_t()
      var started = pthread_cond_t()
      var done = false
      init(_ body: @escaping @Sendable () -> Void, _ intent: Intent, _ name: String?) {
        self.body = body
        self.intent = intent
        self.name = name
        pthread_mutex_init(&ready, nil)
        pthread_cond_init(&started, nil)
      }
    }
    let start = Start(body, intent, name)
    var handle = pthread_t()
    let arg = Unmanaged.passRetained(start).toOpaque()
    let r = pthread_create(&handle, nil, { arg in
      let start = Unmanaged<Start>.fromOpaque(arg!).takeRetainedValue()
      if let name = start.name { td_linux_set_thread_name(name) }
      let admission = Thread.apply(start.intent)
      pthread_mutex_lock(&start.ready)
      start.admission = admission
      start.done = true
      pthread_cond_signal(&start.started)
      pthread_mutex_unlock(&start.ready)
      start.body()
      return nil
    }, arg)
    guard r == 0 else {
      Unmanaged<Start>.fromOpaque(arg).release()
      throw .system(r)
    }
    pthread_mutex_lock(&start.ready)
    while !start.done { pthread_cond_wait(&start.started, &start.ready) }
    pthread_mutex_unlock(&start.ready)
    return Thread(handle: handle, admission: start.admission)
  }

  /// Waits for the thread to finish.
  public consuming func join() {
    pthread_join(handle, nil)
    discard self
  }

  deinit { pthread_detach(handle) }

  /// Applies an intent to the calling thread; what was granted.
  static func apply(_ intent: Intent) -> Admission {
    switch intent {
    case .realtime(let period, let budget, let deadline):
      if td_linux_sched_deadline(budget.nanoseconds, deadline.nanoseconds, period.nanoseconds) == 0 {
        return .deadline
      }
      if td_linux_sched_fifo(10) == 0 { return .fixedPriority }
      return .refused(.noRealtimePrivilege)
    case .frame, .interactive:
      return .notRealtime
    case .throughput:
      _ = td_linux_sched_batch()
      return .notRealtime
    case .background:
      _ = td_linux_sched_idle()
      return .notRealtime
    }
  }
}

/// A mutex that lends its holder the priority of whoever waits on it
/// (priority inheritance), so a real-time thread isn't stuck behind a
/// lower-priority holder.
public final class Mutex: @unchecked Sendable {
  var mutex = pthread_mutex_t()

  public init() {
    var attr = pthread_mutexattr_t()
    pthread_mutexattr_init(&attr)
    pthread_mutexattr_setprotocol(&attr, Int32(PTHREAD_PRIO_INHERIT))
    pthread_mutex_init(&mutex, &attr)
    pthread_mutexattr_destroy(&attr)
  }

  deinit { pthread_mutex_destroy(&mutex) }

  public func withLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    pthread_mutex_lock(&mutex)
    defer { pthread_mutex_unlock(&mutex) }
    return try body()
  }
}
