// SPDX-License-Identifier: BSD-3-Clause

// The SDK's Trace module (sdk.md §1): zones, flows, counters and marks,
// written into this process's trace region (docs/trace-format.md). A
// disabled trace point costs one load of the enabled mask and a branch.
// Hosted, the region is a file under $TODHCHAI_TRACE, mapped shared.

import Glibc
import TDTraceCPU
@_exported import TraceFormat

public enum Trace {
  /// The enabled categories. Zero until a region is started.
  @usableFromInline nonisolated(unsafe) static var mask: UInt64 = 0

  /// The region, once started.
  @usableFromInline nonisolated(unsafe) static var region: UnsafeMutableRawPointer?
  nonisolated(unsafe) static var startLock = pthread_mutex_t()
  nonisolated(unsafe) static var startAttempted = false

  /// Whether points in `category` are being recorded: one load and a branch.
  @inlinable @inline(__always)
  public static func enabled(_ category: TraceCategory) -> Bool {
    mask & category.rawValue != 0
  }

  /// Starts recording if $TODHCHAI_TRACE names a directory: categories from
  /// $TODHCHAI_TRACE_CATEGORIES (default all), circular if
  /// $TODHCHAI_TRACE_CIRCULAR is set. Called by the first trace name, so a
  /// program needn't call it. Returns whether recording.
  @discardableResult
  public static func startFromEnvironment() -> Bool {
    pthread_mutex_lock(&startLock)
    defer { pthread_mutex_unlock(&startLock) }
    if startAttempted { return region != nil }
    startAttempted = true
    guard let dir = getenv("TODHCHAI_TRACE").map({ String(cString: $0) }), !dir.isEmpty else { return false }
    let categories = getenv("TODHCHAI_TRACE_CATEGORIES").flatMap { TraceCategory(names: String(cString: $0)) }
    let circular = getenv("TODHCHAI_TRACE_CIRCULAR") != nil
    return startLocked(path: "\(dir)/\(getpid()).trace", categories: categories ?? .all, circular: circular)
  }

  /// Starts recording into `path`, replacing any recording in progress
  /// (tests use this). Threads that already wrote keep their old rings, so
  /// a new recording sees only threads that start writing after it, and
  /// names interned before the restart don't resolve in the new one.
  @discardableResult
  public static func start(path: String, categories: TraceCategory = .all, circular: Bool = false,
                           rings: Int = 64, recordsPerRing: Int = 1 << 15) -> Bool {
    pthread_mutex_lock(&startLock)
    defer { pthread_mutex_unlock(&startLock) }
    startAttempted = true
    mask = 0
    region = nil  // the old mapping stays, for any thread still writing to it
    return startLocked(path: path, categories: categories, circular: circular, rings: rings,
                       recordsPerRing: recordsPerRing)
  }

  static func startLocked(path: String, categories: TraceCategory, circular: Bool, rings: Int = 64,
                          recordsPerRing: Int = 1 << 15) -> Bool {
    guard region == nil else { return true }
    var capacity = 1
    while capacity < recordsPerRing { capacity <<= 1 }  // a power of two
    let stringsSize = 256 << 10
    let ringSize = TraceFormat.ringHeaderSize + capacity * TraceFormat.recordSize
    let size = TraceFormat.headerSize + stringsSize + rings * ringSize
    let fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0 else { return false }
    let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard let p, p != MAP_FAILED else { return false }

    let start = td_trace_ticks()
    func put<T: FixedWidthInteger>(_ v: T, _ offset: Int) { p.storeBytes(of: v.littleEndian, toByteOffset: offset, as: T.self) }
    put(TraceFormat.regionMagic, 0)
    put(TraceFormat.version, 4)
    put(calibrateCounterHz(), TraceFormat.counterHz)
    put(start, TraceFormat.start)
    put(UInt32(truncatingIfNeeded: getpid()), TraceFormat.processID)
    put(UInt32(rings), TraceFormat.ringCount)
    put(UInt64(ringSize), TraceFormat.ringSize)
    put(UInt64(TraceFormat.headerSize), TraceFormat.stringsOffset)
    put(UInt64(stringsSize), TraceFormat.stringsSize)
    put(UInt64(0), TraceFormat.stringsUsed)
    put(UInt64(TraceFormat.headerSize + stringsSize), TraceFormat.ringsOffset)
    put(UInt32(0), TraceFormat.ringsClaimed)
    put(circular ? TraceFormat.flagCircular : 0, TraceFormat.flags)
    put(categories.rawValue, TraceFormat.categories)
    region = p
    mask = categories.rawValue
    return true
  }

  /// Stops recording: later trace points do nothing. The region stays
  /// mapped, so a thread mid-record finishes safely.
  public static func stop() { mask = 0 }

  /// The cycle counter's frequency, measured against CLOCK_MONOTONIC over
  /// 10 ms.
  static func calibrateCounterHz() -> UInt64 {
    func ns() -> UInt64 {
      var ts = timespec()
      clock_gettime(CLOCK_MONOTONIC, &ts)
      return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
    let t0 = td_trace_ticks(), n0 = ns()
    var sleep = timespec(tv_sec: 0, tv_nsec: 10_000_000)
    nanosleep(&sleep, nil)
    let t1 = td_trace_ticks(), n1 = ns()
    return (t1 &- t0) * 1_000_000_000 / max(n1 &- n0, 1)
  }

  // MARK: Names

  /// Appends `text` to the string table; its id, or 0 if there's no room.
  static func intern(_ text: StaticString) -> UInt64 {
    guard let p = region else { return 0 }
    let length = text.utf8CodeUnitCount
    let entry = 4 + (length + 3) & ~3
    let tableSize = Int(p.load(fromByteOffset: TraceFormat.stringsSize, as: UInt64.self))
    let offset = Int(td_trace_fetch_add_u64(p + TraceFormat.stringsUsed, UInt64(entry)))
    guard offset + entry <= tableSize else { return 0 }
    let at = p + TraceFormat.headerSize + offset
    at.storeBytes(of: UInt32(length).littleEndian, as: UInt32.self)
    text.withUTF8Buffer { (at + 4).copyMemory(from: $0.baseAddress!, byteCount: length) }
    return UInt64(offset)
  }

  // MARK: Writing

  /// Writes one record into the calling thread's ring.
  @usableFromInline
  static func write(_ kind: TraceKind, time: UInt64, a: UInt64, b: UInt64) {
    var ring = td_trace_thread_ring()
    if ring == nil { ring = claimRing() }
    guard let ring, ring != UnsafeMutableRawPointer(bitPattern: 1) else { return }
    let head = ring.load(fromByteOffset: TraceFormat.ringHead, as: UInt64.self)
    let capacity = ring.load(fromByteOffset: TraceFormat.ringCapacity, as: UInt64.self)
    if head >= capacity && ring.load(fromByteOffset: TraceFormat.ringMode, as: UInt32.self) == 0 {
      let dropped = ring.load(fromByteOffset: TraceFormat.ringDropped, as: UInt64.self)
      if dropped == 0 { ring.storeBytes(of: time, toByteOffset: TraceFormat.ringFirstDrop, as: UInt64.self) }
      ring.storeBytes(of: time, toByteOffset: TraceFormat.ringLastDrop, as: UInt64.self)
      ring.storeBytes(of: dropped + 1, toByteOffset: TraceFormat.ringDropped, as: UInt64.self)
      return
    }
    let r = ring + TraceFormat.ringHeaderSize + Int(head & (capacity - 1)) * TraceFormat.recordSize
    r.storeBytes(of: time, as: UInt64.self)
    r.storeBytes(of: kind.rawValue, toByteOffset: 8, as: UInt16.self)
    r.storeBytes(of: UInt16.max, toByteOffset: 10, as: UInt16.self)  // the CPU isn't known hosted
    r.storeBytes(of: ring.load(fromByteOffset: TraceFormat.ringTid, as: UInt32.self), toByteOffset: 12, as: UInt32.self)
    r.storeBytes(of: a, toByteOffset: 16, as: UInt64.self)
    r.storeBytes(of: b, toByteOffset: 24, as: UInt64.self)
    td_trace_store_release_u64(ring + TraceFormat.ringHead, head + 1)
  }

  /// Claims the next ring for this thread, or marks it as having none.
  static func claimRing() -> UnsafeMutableRawPointer? {
    guard let p = region else { return nil }
    let count = p.load(fromByteOffset: TraceFormat.ringCount, as: UInt32.self)
    let index = td_trace_fetch_add_u32(p + TraceFormat.ringsClaimed, 1)
    guard index < count else {
      td_trace_set_thread_ring(UnsafeMutableRawPointer(bitPattern: 1))
      return nil
    }
    let ringSize = Int(p.load(fromByteOffset: TraceFormat.ringSize, as: UInt64.self))
    let ring = p + Int(p.load(fromByteOffset: TraceFormat.ringsOffset, as: UInt64.self)) + Int(index) * ringSize
    let capacity = UInt64((ringSize - TraceFormat.ringHeaderSize) / TraceFormat.recordSize)
    let pid = p.load(fromByteOffset: TraceFormat.processID, as: UInt32.self)
    ring.storeBytes(of: capacity, toByteOffset: TraceFormat.ringCapacity, as: UInt64.self)
    ring.storeBytes(of: p.load(fromByteOffset: TraceFormat.counterHz, as: UInt64.self),
                    toByteOffset: TraceFormat.ringFrequency, as: UInt64.self)
    ring.storeBytes(of: p.load(fromByteOffset: TraceFormat.start, as: UInt64.self),
                    toByteOffset: TraceFormat.ringSession, as: UInt64.self)
    let circular = p.load(fromByteOffset: TraceFormat.flags, as: UInt32.self) & TraceFormat.flagCircular
    ring.storeBytes(of: circular, toByteOffset: TraceFormat.ringMode, as: UInt32.self)
    ring.storeBytes(of: UInt32.max, toByteOffset: TraceFormat.ringCPU, as: UInt32.self)
    ring.storeBytes(of: TraceFormat.ringMagic, toByteOffset: TraceFormat.ringMagicOffset, as: UInt32.self)
    ring.storeBytes(of: (pid & 0xfffff) << 12 | (index + 1), toByteOffset: TraceFormat.ringTid, as: UInt32.self)
    td_trace_set_thread_ring(ring)
    return ring
  }

  /// The cycle counter, the time base of every record.
  @inlinable @inline(__always)
  public static func now() -> UInt64 { td_trace_ticks() }

  // MARK: Trace points

  /// Runs `body` as a zone named `name`, recorded when it ends.
  @inlinable
  public static func zone<R, E: Error>(_ name: TraceName, _ category: TraceCategory = .app,
                                       _ body: () throws(E) -> R) throws(E) -> R {
    guard enabled(category) else { return try body() }
    let start = td_trace_ticks()
    defer { write(.zone, time: start, a: td_trace_ticks(), b: name.id) }
    return try body()
  }

  /// Records a zone from `start` (from `now()`) to now.
  @inlinable
  public static func zone(_ name: TraceName, _ category: TraceCategory = .app, since start: UInt64) {
    guard enabled(category) else { return }
    write(.zone, time: start, a: td_trace_ticks(), b: name.id)
  }

  /// Records a step of flow `id`, which joins records across threads and
  /// processes.
  @inlinable
  public static func flow(_ id: UInt64, _ name: TraceName, _ category: TraceCategory = .app) {
    guard enabled(category) else { return }
    write(.flow, time: td_trace_ticks(), a: id, b: name.id)
  }

  /// Records a counter's value.
  @inlinable
  public static func counter(_ name: TraceName, _ value: Int64, _ category: TraceCategory = .app) {
    guard enabled(category) else { return }
    write(.counter, time: td_trace_ticks(), a: name.id, b: UInt64(bitPattern: value))
  }

  /// Records a mark: a label of at most 16 bytes of UTF-8 (longer ones are
  /// cut).
  public static func mark(_ label: StaticString) {
    if !startAttempted { startFromEnvironment() }
    guard enabled(.mark) else { return }
    var a: UInt64 = 0, b: UInt64 = 0
    label.withUTF8Buffer { utf8 in
      for (i, byte) in utf8.prefix(16).enumerated() {
        if i < 8 { a |= UInt64(byte) << (8 * i) } else { b |= UInt64(byte) << (8 * (i - 8)) }
      }
    }
    write(.mark, time: td_trace_ticks(), a: a, b: b)
  }
}

/// A name for zones, flows and counters, interned once in the region's
/// string table. Declare one per call site, as a `static let`:
///
///     static let frameName = TraceName("frame")
public struct TraceName: Sendable {
  public let id: UInt64

  public init(_ text: StaticString) {
    Trace.startFromEnvironment()
    id = Trace.intern(text)
  }
}
