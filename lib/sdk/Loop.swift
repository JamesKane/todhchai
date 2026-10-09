// SPDX-License-Identifier: BSD-3-Clause

// Loop (sdk.md §2): the one wait. The app owns the loop, and a thread
// blocks in `wait` until something happens: a timer, a watched file, a
// message or wake from another thread, or a request to quit. An idle loop
// with nothing due sleeps in the kernel and wakes zero times (principle 9).
//
// Hosted on Linux: epoll over one eventfd (wake, post, quit), one timerfd
// (the earliest timer), and the watched file descriptors. Native, it is one
// croi port.

import Glibc
import TDLinux
import Trace

public enum LoopError: Error, Equatable {
  /// The kernel refused a resource the loop needs (errno).
  case system(Int32)
  /// The ID names nothing this loop has.
  case unknown
}

/// What other threads use to reach a loop: `wake` and `post`. Copyable and
/// Sendable; the loop itself stays with its thread.
public struct LoopRemote: Sendable {
  let shared: LoopShared

  /// Wakes the loop. Wakes are coalesced: many before the loop runs make
  /// one `.wake` event.
  public func wake() { shared.signal(wake: true) }

  /// Posts a message; it arrives as a `.message` event, in order.
  public func post(_ message: Message) {
    shared.lock()
    shared.messages.append(message)
    shared.unlock()
    shared.signal(wake: false)
  }
}

/// State shared between a loop and its remotes.
final class LoopShared: @unchecked Sendable {
  let eventFD: Int32
  var mutex = pthread_mutex_t()
  var messages: [Message] = []
  var wakeRequested = false
  var signaled = false  // the eventfd has been written since the loop last read it
  var quitRequested = false

  init(eventFD: Int32) {
    self.eventFD = eventFD
    pthread_mutex_init(&mutex, nil)
  }

  func lock() { pthread_mutex_lock(&mutex) }
  func unlock() { pthread_mutex_unlock(&mutex) }

  /// Notes a wake (or just new messages) and writes the eventfd if the
  /// loop hasn't been signaled since it last looked.
  func signal(wake: Bool) {
    lock()
    if wake { wakeRequested = true }
    let write = !signaled
    signaled = true
    unlock()
    if write {
      var one: UInt64 = 1
      _ = Glibc.write(eventFD, &one, 8)
    }
  }
}

/// SIGINT and SIGTERM go to the first loop made, as `.quit`.
nonisolated(unsafe) var quitTarget: LoopShared?
nonisolated(unsafe) var quitFD: Int32 = -1

public struct Loop: ~Copyable {
  struct Timer {
    var id: TimerID
    var deadline: Deadline
    var leeway: Duration
    var interval: Duration?
  }

  let epoll: Int32
  let timerFD: Int32
  let shared: LoopShared
  var timers: [Timer] = []
  var watches: [UInt64: Int32] = [:]  // watch id → fd
  var nextID: UInt64 = 1
  var seq: UInt64 = 0
  var buffer: [Event] = []
  var ready = [epoll_event](repeating: epoll_event(), count: 32)
  var armedFor: UInt64 = 0  // the timerfd's current expiry, in ns; 0 if disarmed

  /// How many times `wait` has returned from the kernel: the number the
  /// idle-wakeup budget counts.
  public private(set) var wakeups: UInt64 = 0

  static let eventToken: UInt64 = 0
  static let timerToken: UInt64 = 1
  static let waitName = TraceName("loop.wait")

  public init() throws(LoopError) {
    let epoll = epoll_create1(Int32(EPOLL_CLOEXEC))
    let event = eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
    let timer = timerfd_create(CLOCK_MONOTONIC, Int32(TFD_CLOEXEC | TFD_NONBLOCK))
    guard epoll >= 0, event >= 0, timer >= 0 else {
      let e = errno
      for fd in [epoll, event, timer] where fd >= 0 { close(fd) }
      throw .system(e)
    }
    self.epoll = epoll
    self.timerFD = timer
    self.shared = LoopShared(eventFD: event)
    for (fd, token) in [(event, Self.eventToken), (timer, Self.timerToken)] {
      var ev = epoll_event(events: EPOLLIN.rawValue, data: epoll_data_t(u64: token))
      epoll_ctl(epoll, EPOLL_CTL_ADD, fd, &ev)
    }
    if quitTarget == nil {
      quitTarget = shared
      quitFD = event
      for sig in [SIGINT, SIGTERM] {
        var action = sigaction()
        action.__sigaction_handler.sa_handler = { _ in
          quitTarget?.quitRequested = true
          var one: UInt64 = 1
          _ = write(quitFD, &one, 8)  // async-signal-safe
        }
        sigemptyset(&action.sa_mask)
        sigaction(sig, &action, nil)
      }
    }
  }

  deinit {
    if quitTarget === shared { quitTarget = nil }
    close(epoll)
    close(timerFD)
    close(shared.eventFD)
  }

  /// A handle for other threads to wake this loop or post to it.
  public var remote: LoopRemote { LoopRemote(shared: shared) }

  /// Wakes the loop from its own thread (other threads use `remote`).
  public func wake() { remote.wake() }

  /// Posts a message from the loop's own thread.
  public func post(_ message: Message) { remote.post(message) }

  // MARK: Timers

  /// A timer at `deadline`, which may fire up to `leeway` late so that
  /// nearby timers share one wakeup; `repeating` re-arms it that much later
  /// each time, from the deadline, so it doesn't drift.
  public mutating func timer(at deadline: Deadline, leeway: Duration = .zero, repeating: Duration? = nil)
    -> TimerID
  {
    let id = TimerID(raw: nextID)
    nextID += 1
    timers.append(Timer(id: id, deadline: deadline, leeway: leeway, interval: repeating))
    arm()
    return id
  }

  public mutating func cancel(_ id: TimerID) {
    timers.removeAll { $0.id == id }
    arm()
  }

  /// Arms the timerfd for the earliest time any timer's window closes:
  /// every timer whose deadline has come by then fires in the same wakeup.
  mutating func arm() {
    let fire = timers.map { $0.deadline.ns &+ $0.leeway.nanoseconds }.min() ?? 0
    guard fire != armedFor else { return }
    armedFor = fire
    var spec = itimerspec()
    if fire != 0 { spec.it_value = Deadline(ns: max(fire, 1)).asTimespec }
    timerfd_settime(timerFD, Int32(TFD_TIMER_ABSTIME), &spec, nil)
  }

  // MARK: Watches

  /// Watches a file descriptor for `interest`; readiness arrives as
  /// `.watch` events while it lasts (level-triggered).
  public mutating func watch(fd: Int32, for interest: Readiness) throws(LoopError) -> WatchID {
    let id = WatchID(raw: nextID)
    nextID += 1
    var mask: UInt32 = 0
    if interest.contains(.readable) { mask |= EPOLLIN.rawValue }
    if interest.contains(.writable) { mask |= EPOLLOUT.rawValue }
    var ev = epoll_event(events: mask, data: epoll_data_t(u64: id.raw + 2))
    guard epoll_ctl(epoll, EPOLL_CTL_ADD, fd, &ev) == 0 else { throw .system(errno) }
    watches[id.raw] = fd
    return id
  }

  public mutating func unwatch(_ id: WatchID) throws(LoopError) {
    guard let fd = watches.removeValue(forKey: id.raw) else { throw .unknown }
    epoll_ctl(epoll, EPOLL_CTL_DEL, fd, nil)
  }

  // MARK: Waiting

  /// Blocks until there is something to report, or until `deadline` (with
  /// `leeway`) if given, and returns what happened.
  public mutating func wait(until deadline: Deadline? = nil, leeway: Duration = .zero) -> Events {
    var oneShot: TimerID?
    if let deadline { oneShot = timer(at: deadline, leeway: leeway) }
    defer { if let oneShot { cancel(oneShot) } }
    buffer.removeAll(keepingCapacity: true)
    collect(blocking: true, deadlineTimer: oneShot)
    return Events(items: buffer)
  }

  /// Returns what has already happened, without blocking.
  public mutating func poll() -> Events {
    buffer.removeAll(keepingCapacity: true)
    collect(blocking: false, deadlineTimer: nil)
    return Events(items: buffer)
  }

  mutating func collect(blocking: Bool, deadlineTimer: TimerID?) {
    while true {
      let start = Trace.now()
      let n = epoll_wait(epoll, &ready, Int32(ready.count), blocking ? -1 : 0)
      if n < 0 && errno == EINTR { continue }
      if blocking {
        wakeups += 1
        Trace.zone(Self.waitName, .app, since: start)
      }
      for i in 0..<max(Int(n), 0) {
        let event = ready[i]
        switch event.data.u64 {
        case Self.eventToken: drainShared()
        case Self.timerToken: fireTimers(deadlineTimer: deadlineTimer)
        case let token:
          var readiness: Readiness = []
          let e = event.events
          if e & EPOLLIN.rawValue != 0 { readiness.insert(.readable) }
          if e & EPOLLOUT.rawValue != 0 { readiness.insert(.writable) }
          if e & EPOLLHUP.rawValue != 0 { readiness.insert(.hangup) }
          if e & EPOLLERR.rawValue != 0 { readiness.insert(.error) }
          append(.watch(WatchID(raw: token - 2), readiness))
        }
      }
      // A wakeup that produced nothing (a timer re-armed for later, a
      // deadline timer firing) still returns if the deadline came.
      if !buffer.isEmpty || !blocking || deadlineFired { break }
    }
    deadlineFired = false
  }

  var deadlineFired = false

  mutating func append(_ payload: Event.Payload) {
    seq += 1
    buffer.append(Event(payload: payload, window: .none, time: .now, seq: seq))
  }

  mutating func drainShared() {
    var count: UInt64 = 0
    _ = read(shared.eventFD, &count, 8)
    shared.lock()
    let messages = shared.messages
    let wake = shared.wakeRequested
    let quit = shared.quitRequested
    shared.messages.removeAll(keepingCapacity: true)
    shared.wakeRequested = false
    shared.quitRequested = false
    shared.signaled = false
    shared.unlock()
    for m in messages { append(.message(m)) }
    if wake { append(.wake) }
    if quit { append(.quit) }
  }

  mutating func fireTimers(deadlineTimer: TimerID?) {
    var expirations: UInt64 = 0
    _ = read(timerFD, &expirations, 8)
    armedFor = 0
    let now = Deadline.now
    var fired: [(TimerID, UInt64)] = []
    for i in timers.indices.reversed() where timers[i].deadline <= now {
      var missed: UInt64 = 0
      if let interval = timers[i].interval, interval.nanoseconds > 0 {
        let step = interval.nanoseconds
        let behind = (now.ns - timers[i].deadline.ns) / step
        missed = behind
        timers[i].deadline.ns += (behind + 1) * step
        fired.append((timers[i].id, missed))
      } else {
        fired.append((timers[i].id, 0))
        timers.remove(at: i)
      }
    }
    for (id, missed) in fired.reversed() {
      if id == deadlineTimer {
        deadlineFired = true
      } else {
        append(.timer(id, missed: missed))
      }
    }
    arm()
  }
}
