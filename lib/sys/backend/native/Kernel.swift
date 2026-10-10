// SPDX-License-Identifier: BSD-3-Clause

// Sys's calls on croi (M3b): each one a system call, with croi's numbers and
// argument packing (../croi/user/include/croi/syscall.h). The runtime
// (lib/sys/native) holds this process's handle and root VMAR and the
// vDSO's clock.
//
// A channel write or call consumes its handles even when it fails (croi
// 869cb83, as Zircon), as Sys promises. Threads' stacks are still
// unmapped by the next thread start; croi now has Zircon's
// vmar_unmap_handle_close_thread_exit (syscall 75) and user TLS, which
// this backend moves to after M3e.

import LibSys
import TDNative

enum Number {
  static let nanosleep: UInt64 = 4
  static let handleClose: UInt64 = 10
  static let handleDuplicate: UInt64 = 11
  static let handleReplace: UInt64 = 12
  static let objectSignal: UInt64 = 20
  static let objectWaitOne: UInt64 = 21
  static let objectWaitAsync: UInt64 = 22
  static let eventCreate: UInt64 = 30
  static let portCreate: UInt64 = 31
  static let portQueue: UInt64 = 32
  static let portWait: UInt64 = 33
  static let portCancel: UInt64 = 34
  static let vmoCreate: UInt64 = 40
  static let vmoRead: UInt64 = 41
  static let vmoWrite: UInt64 = 42
  static let vmoGetSize: UInt64 = 44
  static let vmoSetCachePolicy: UInt64 = 46
  static let vmoCreatePhysical: UInt64 = 47
  static let jobCreate: UInt64 = 60
  static let processCreate: UInt64 = 61
  static let processStart: UInt64 = 62
  static let processExit: UInt64 = 63
  static let threadCreate: UInt64 = 64
  static let threadStart: UInt64 = 65
  static let taskKill: UInt64 = 67
  static let processInfo: UInt64 = 68
  static let vmarMap: UInt64 = 71
  static let vmarUnmap: UInt64 = 72
  static let channelCreate: UInt64 = 80
  static let channelWrite: UInt64 = 81
  static let channelRead: UInt64 = 82
  static let channelCall: UInt64 = 83
  static let eventpairCreate: UInt64 = 84
  static let objectSignalPeer: UInt64 = 85
  static let objectGetInfo: UInt64 = 86
  static let futexWait: UInt64 = 90
  static let futexWake: UInt64 = 91
  static let timerCreate: UInt64 = 95
  static let timerSet: UInt64 = 96
  static let timerCancel: UInt64 = 97
  static let debuglogCreate: UInt64 = 110
  static let debuglogRead: UInt64 = 112
  static let resourceCreate: UInt64 = 130
  static let ioportsRequest: UInt64 = 131
  static let ioportsRelease: UInt64 = 132
  static let threadExit: UInt64 = 2
}

/// A system call: its result, a status if negative.
@inline(__always)
func sys(_ n: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0, _ a4: UInt64 = 0,
         _ a5: UInt64 = 0) -> Int64
{
  unsafe td_syscall6(n, a0, a1, a2, a3, a4, a5)
}

/// Throws the status a call returned, if it failed.
@inline(__always)
func check(_ result: Int64) throws(Status) {
  if result < 0 { throw Status(rawValue: Int32(truncatingIfNeeded: result)) ?? .internal }
}

/// An address for the kernel to read or write through.
@inline(__always)
func address<T>(_ p: UnsafeMutablePointer<T>) -> UInt64 { UInt64(UInt(bitPattern: p)) }
@inline(__always)
func address(_ p: UnsafeRawPointer?) -> UInt64 { UInt64(UInt(bitPattern: p)) }

/// Calls `body` with a place for one out value, and returns it.
@inline(__always)
func out<T>(_ initial: T, _ body: (UInt64) -> Int64) throws(Status) -> T {
  var value = initial
  let r = unsafe withUnsafeMutablePointer(to: &value) { unsafe body(address($0)) }
  try check(r)
  return value
}

enum Kernel {
  static func close(_ h: UInt32) { _ = sys(Number.handleClose, UInt64(h)) }

  static func duplicate(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.handleDuplicate, UInt64(h), UInt64(r.rawValue), $0) }
  }

  static func replace(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.handleReplace, UInt64(h), UInt64(r.rawValue), $0) }
  }

  /// object_get_info(HANDLE_BASIC): croi_info_handle_basic_t, 32 bytes.
  static func info(_ h: UInt32) throws(Status) -> HandleInfo {
    let record = try out(InlineArray<4, UInt64>(repeating: 0)) { sys(Number.objectGetInfo, UInt64(h), 2, $0, 32) }
    return HandleInfo(
      koid: record[0], rights: Rights(rawValue: UInt32(truncatingIfNeeded: record[1])),
      type: UInt32(truncatingIfNeeded: record[1] >> 32), relatedKoid: record[2])
  }

  static func signal(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) {
    try check(sys(Number.objectSignal, UInt64(h), UInt64(clear), UInt64(set)))
  }

  static func signalPeer(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) {
    try check(sys(Number.objectSignalPeer, UInt64(h), UInt64(clear), UInt64(set)))
  }

  static func wait(_ h: UInt32, _ signals: UInt32, _ deadline: Int64) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.objectWaitOne, UInt64(h), UInt64(signals), UInt64(bitPattern: deadline), $0) }
  }

  static func waitAsync(_ h: UInt32, _ port: UInt32, _ key: UInt64, _ signals: UInt32, _ edge: Bool) throws(Status) {
    // ZX_WAIT_ASYNC_EDGE.
    try check(sys(Number.objectWaitAsync, UInt64(h), UInt64(port), key, UInt64(signals), edge ? 2 : 0))
  }

  // MARK: Channels

  static func channelCreate() throws(Status) -> (UInt32, UInt32) {
    let ends = try out((UInt32(0), UInt32(0))) { p in sys(Number.channelCreate, 0, p, p + 4) }
    return ends
  }

  static func channelWrite(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32]) throws(Status) {
    let r = unsafe bytes.withUnsafeBytes { b in
      unsafe handles.withUnsafeBytes { hs in
        unsafe sys(Number.channelWrite, UInt64(h), 0, address(b.baseAddress), UInt64(b.count), address(hs.baseAddress),
            UInt64(handles.count))
      }
    }
    try check(r)
  }

  /// channel_read, sized first: asked with no room, croi says how large the
  /// next message is and leaves it queued (Zircon's BUFFER_TOO_SMALL), so
  /// the arrays are made to fit, uninitialized. Another reader may take it
  /// meanwhile; then the next one is sized.
  static func channelRead(_ h: UInt32) throws(Status) -> Channel.Message {
    var actual: UInt64 = 0
    while true {
      let size = unsafe withUnsafeMutablePointer(to: &actual) { a in
        unsafe sys(Number.channelRead, UInt64(h), 0, 0, 0, 0, address(a))
      }
      if size == 0 { return Channel.Message(bytes: [], handles: []) }  // an empty message, read
      guard size == Int64(Status.bufferTooSmall.rawValue) else {
        try check(size)
        throw .internal
      }
      let count = Int(actual & 0xFFFF_FFFF), handleCount = Int(actual >> 32)
      // Trivial values: uninitialized until the read fills them.
      var bytes = unsafe [UInt8](unsafeUninitializedCapacity: count) { _, n in n = count }
      var handles = unsafe [UInt32](unsafeUninitializedCapacity: handleCount) { _, n in n = handleCount }
      let r = unsafe bytes.withUnsafeMutableBytes { b in
        unsafe handles.withUnsafeMutableBytes { hs in
          unsafe withUnsafeMutablePointer(to: &actual) { a in
            unsafe sys(Number.channelRead, UInt64(h), 0, address(b.baseAddress), address(hs.baseAddress),
                UInt64(count) | UInt64(handleCount) << 32, address(a))
          }
        }
      }
      if r == Int64(Status.bufferTooSmall.rawValue) { continue }  // another reader took it: the next
      try check(r)
      return Channel.Message(bytes: bytes, handles: handles)
    }
  }

  /// channel_call with croi_channel_call_args_t: four pointers, then the
  /// written and readable counts as 32-bit words.
  static func channelCall(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32], _ deadline: Int64) throws(Status)
    -> Channel.Message
  {
    // Room for the largest reply (croi drops one that doesn't fit), from
    // the heap's classes and not zeroed.
    var reply = unsafe [UInt8](unsafeUninitializedCapacity: Channel.maxBytes) { _, n in n = Channel.maxBytes }
    var replyHandles = unsafe [UInt32](unsafeUninitializedCapacity: Channel.maxHandles) { _, n in
      n = Channel.maxHandles
    }
    var actual = (UInt32(0), UInt32(0))
    let r = unsafe bytes.withUnsafeBytes { wb in
      unsafe handles.withUnsafeBytes { wh in
        unsafe reply.withUnsafeMutableBytes { rb in
          unsafe replyHandles.withUnsafeMutableBytes { rh in
            var args = InlineArray<6, UInt64>(repeating: 0)
            args[0] = unsafe address(wb.baseAddress)
            args[1] = unsafe address(wh.baseAddress)
            args[2] = unsafe address(rb.baseAddress)
            args[3] = unsafe address(rh.baseAddress)
            args[4] = UInt64(wb.count) | UInt64(handles.count) << 32
            args[5] = UInt64(Channel.maxBytes) | UInt64(Channel.maxHandles) << 32
            return unsafe withUnsafeMutablePointer(to: &args) { a in
              unsafe withUnsafeMutablePointer(to: &actual) { act in
                unsafe sys(Number.channelCall, UInt64(h), 0, UInt64(bitPattern: deadline), address(a), address(act),
                    address(act) + 4)
              }
            }
          }
        }
      }
    }
    try check(r)
    reply.removeLast(Channel.maxBytes - Int(actual.0))
    replyHandles.removeLast(Channel.maxHandles - Int(actual.1))
    return Channel.Message(bytes: reply, handles: replyHandles)
  }

  // MARK: Events and ports

  static func eventCreate() throws(Status) -> UInt32 { try out(UInt32(0)) { sys(Number.eventCreate, 0, $0) } }

  static func eventPairCreate() throws(Status) -> (UInt32, UInt32) {
    try out((UInt32(0), UInt32(0))) { p in sys(Number.eventpairCreate, 0, p, p + 4) }
  }

  static func portCreate() throws(Status) -> UInt32 { try out(UInt32(0)) { sys(Number.portCreate, 0, $0) } }

  /// croi_port_packet_t: key, type and status, four payload words.
  static func record(_ p: Packet) -> InlineArray<6, UInt64> {
    var r = InlineArray<6, UInt64>(repeating: 0)
    r[0] = p.key
    r[1] = UInt64(p.type) | UInt64(UInt32(bitPattern: p.status)) << 32
    r[2] = p.payload.0
    r[3] = p.payload.1
    r[4] = p.payload.2
    r[5] = p.payload.3
    return r
  }

  static func portQueue(_ port: UInt32, _ packet: Packet) throws(Status) {
    _ = try out(record(packet)) { sys(Number.portQueue, UInt64(port), $0) }
  }

  static func portWait(_ port: UInt32, _ deadline: Int64) throws(Status) -> Packet {
    let r = try out(InlineArray<6, UInt64>(repeating: 0)) {
      sys(Number.portWait, UInt64(port), UInt64(bitPattern: deadline), $0)
    }
    return Packet(
      key: r[0], type: UInt32(truncatingIfNeeded: r[1]), status: Int32(truncatingIfNeeded: r[1] >> 32),
      payload: (r[2], r[3], r[4], r[5]))
  }

  static func portCancel(_ port: UInt32, _ source: UInt32, _ key: UInt64) throws(Status) {
    try check(sys(Number.portCancel, UInt64(port), UInt64(source), key))
  }

  // MARK: VMOs

  static let pageSize = 4096

  /// `n` rounded up to a page: croi refuses sizes and lengths that aren't
  /// (Zircon rounds a VMO's size up), and Sys promises pages.
  static func pages(_ n: Int) -> Int { (n + pageSize - 1) & ~(pageSize - 1) }

  static func vmoCreate(_ size: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.vmoCreate, UInt64(pages(size)), 0, $0) }
  }

  static func vmoSize(_ h: UInt32) throws(Status) -> Int {
    Int(try out(UInt64(0)) { sys(Number.vmoGetSize, UInt64(h), $0) })
  }

  static func vmoRead(_ h: UInt32, _ offset: Int, _ count: Int) throws(Status) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let r = unsafe bytes.withUnsafeMutableBytes { b in
      unsafe sys(Number.vmoRead, UInt64(h), address(b.baseAddress), UInt64(offset), UInt64(count))
    }
    try check(r)
    return bytes
  }

  static func vmoWrite(_ h: UInt32, _ offset: Int, _ bytes: [UInt8]) throws(Status) {
    let r = unsafe bytes.withUnsafeBytes { b in
      unsafe sys(Number.vmoWrite, UInt64(h), address(b.baseAddress), UInt64(offset), UInt64(b.count))
    }
    try check(r)
  }

  /// vmar_map on the root VMAR: the VMAR and its options share the first
  /// argument (CROI_VM_PERM_READ 1, _WRITE 2).
  static func vmoMap(_ h: UInt32, _ offset: Int, _ length: Int, _ writable: Bool) throws(Status)
    -> UnsafeMutableRawPointer
  {
    let perms: UInt64 = writable ? 3 : 1
    let mapped = try out(UInt64(0)) {
      sys(Number.vmarMap, UInt64(Runtime.vmarRoot) | perms << 32, 0, UInt64(h), UInt64(offset), UInt64(pages(length)), $0)
    }
    guard let p = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapped)) else { throw .internal }
    return unsafe p
  }

  static func vmoUnmap(_ address: UnsafeMutableRawPointer, _ length: Int) {
    _ = sys(Number.vmarUnmap, UInt64(Runtime.vmarRoot), UInt64(UInt(bitPattern: address)), UInt64(pages(length)))
  }

  // MARK: Resources and physical memory (croi K9a)

  static func vmoCreatePhysical(_ resource: UInt32, _ address: UInt64, _ size: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.vmoCreatePhysical, UInt64(resource), address, UInt64(pages(size)), $0) }
  }

  static func vmoSetCachePolicy(_ h: UInt32, _ policy: VMO.CachePolicy) throws(Status) {
    try check(sys(Number.vmoSetCachePolicy, UInt64(h), UInt64(policy.rawValue)))
  }

  /// resource_create: the parent and options share the first argument.
  static func resourceCreate(_ parent: UInt32, _ options: UInt32, _ base: UInt64, _ size: UInt64, _ name: String)
    throws(Status) -> UInt32
  {
    var bytes = Array(name.utf8.prefix(31))
    return try out(UInt32(0)) { p in
      unsafe bytes.withUnsafeMutableBytes { n in
        unsafe sys(Number.resourceCreate, UInt64(parent) | UInt64(options) << 32, base, size, address(n.baseAddress),
            UInt64(n.count), p)
      }
    }
  }

  /// object_get_info(RESOURCE): croi_info_resource_t, 56 bytes.
  static func resourceInfo(_ h: UInt32) throws(Status) -> ResourceInfo {
    let r = try out(InlineArray<7, UInt64>(repeating: 0)) { sys(Number.objectGetInfo, UInt64(h), 18, $0, 56) }
    var name: [UInt8] = []
    for i in 3..<7 {
      for b in 0..<8 { name.append(UInt8(truncatingIfNeeded: r[i] >> (8 * UInt64(b)))) }
    }
    if let end = name.firstIndex(of: 0) { name.removeSubrange(end...) }
    return ResourceInfo(
      kind: UInt32(truncatingIfNeeded: r[0]), flags: UInt32(truncatingIfNeeded: r[0] >> 32), base: r[1], size: r[2],
      name: String(decoding: name, as: UTF8.self))
  }

  static func ioportsRequest(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) {
    try check(sys(Number.ioportsRequest, UInt64(resource), UInt64(base), UInt64(count)))
  }

  static func ioportsRelease(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) {
    try check(sys(Number.ioportsRelease, UInt64(resource), UInt64(base), UInt64(count)))
  }

  static func portIn(_ port: UInt16, _ width: Int) -> UInt32 {
    #if arch(x86_64)
      td_port_in(port, UInt32(width))
    #else
      UInt32.max >> (32 - 8 * width)  // no ports: what a missing device gives
    #endif
  }

  static func portOut(_ port: UInt16, _ width: Int, _ value: UInt32) {
    #if arch(x86_64)
      td_port_out(port, UInt32(width), value)
    #endif
  }

  // MARK: The debuglog

  /// debuglog_create: CROI_LOG_FLAG_READABLE needs the debuglog resource.
  static func debuglogCreate(_ resource: UInt32, readable: Bool) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.debuglogCreate, UInt64(resource), readable ? 0x4000_0000 : 0, $0) }
  }

  /// debuglog_read into croi_log_record_t (a 40-byte header, then up to
  /// 216 bytes of text): sequence, padding, datalen, severity, flags,
  /// timestamp, pid, tid.
  static func debuglogRead(_ h: UInt32) throws(Status) -> Debuglog.Record {
    var buffer = InlineArray<32, UInt64>(repeating: 0)
    let n = unsafe withUnsafeMutablePointer(to: &buffer) { p in unsafe sys(Number.debuglogRead, UInt64(h), 0, address(p), 256) }
    try check(n)
    let length = min(Int(UInt16(truncatingIfNeeded: buffer[1] >> 32)), 216)
    var text: [UInt8] = []
    text.reserveCapacity(length)
    for i in 0..<length { text.append(UInt8(truncatingIfNeeded: buffer[5 + i / 8] >> (8 * UInt64(i % 8)))) }
    return Debuglog.Record(
      sequence: buffer[0], severity: UInt8(truncatingIfNeeded: buffer[1] >> 48), timestamp: Int64(bitPattern: buffer[2]),
      pid: buffer[3], tid: buffer[4], text: text)
  }

  // MARK: Futexes and timers

  static func futexWait(_ word: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64) throws(Status) {
    // No owner: croi's user threads can't yet name themselves (Lock.swift).
    unsafe try check(sys(Number.futexWait, address(word), UInt64(current), 0, UInt64(bitPattern: deadline)))
  }

  static func futexWake(_ word: UnsafeMutablePointer<UInt32>, count: Int) {
    _ = unsafe sys(Number.futexWake, address(word), UInt64(count))
  }

  static func timerCreate() throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.timerCreate, 0, 0, $0) }
  }

  static func timerSet(_ h: UInt32, _ deadline: Int64) throws(Status) {
    try check(sys(Number.timerSet, UInt64(h), UInt64(bitPattern: deadline), 0))
  }

  static func timerCancel(_ h: UInt32) throws(Status) { try check(sys(Number.timerCancel, UInt64(h))) }

  // MARK: Tasks

  static func jobCreate(_ parent: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) { sys(Number.jobCreate, UInt64(parent), 0, $0) }
  }

  /// process_create gives the process and its root VMAR, which the loader
  /// keeps until the process starts (Loader.swift).
  static func processCreate(_ job: UInt32, _ name: String) throws(Status) -> UInt32 {
    var bytes = Array(name.utf8)
    let ends = try out((UInt32(0), UInt32(0))) { p in
      unsafe bytes.withUnsafeMutableBytes { n in
        unsafe sys(Number.processCreate, UInt64(job), address(n.baseAddress), UInt64(n.count), 0, p, p + 4)
      }
    }
    Loader.keep(ends.0, vmar: ends.1)
    return ends.0
  }

  static func threadCreate(_ process: UInt32) throws(Status) -> UInt32 {
    var name = Array("thread".utf8)
    return try out(UInt32(0)) { p in
      unsafe name.withUnsafeMutableBytes { n in
        unsafe sys(Number.threadCreate, UInt64(process), address(n.baseAddress), UInt64(n.count), 0, p)
      }
    }
  }

  static func processStart(_ process: UInt32, _ thread: UInt32, _ arg: UInt32, _ entry: ProgramEntry,
                           _ extra: [(info: UInt32, handle: UInt32)]) throws(Status) {
    try Loader.start(process, thread, arg, entry, extra)
  }

  static func threadStart(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) {
    try Threads.start(thread, body)
  }

  static func kill(_ h: UInt32) throws(Status) { try check(sys(Number.taskKill, UInt64(h))) }

  static func exit(_ code: Int64) -> Never { LibSys.exit(code) }

  /// croi_process_info_t: the return code, then flags (started 1, exited 2).
  static func processInfo(_ h: UInt32) throws(Status) -> ProcessInfo {
    let r = try out((Int64(0), UInt32(0), UInt32(0))) { sys(Number.processInfo, UInt64(h), $0) }
    return ProcessInfo(returnCode: r.0, started: r.1 & 1 != 0, exited: r.1 & 2 != 0)
  }

  static func processSelf() throws(Status) -> UInt32 {
    try duplicate(Runtime.processSelf, .sameRights)
  }

  static func now() -> Int64 { Runtime.monotonic() }

  /// No UTC clock on croi yet (requirement 15): the monotonic clock.
  static func realtime() -> Int64 { Runtime.monotonic() }

  static func sleep(_ deadline: Int64) { _ = sys(Number.nanosleep, UInt64(bitPattern: deadline)) }
}

/// Threads started from Swift: each gets a stack of its own mapped from a
/// VMO, and runs its body from `td_thread_entry`. Finished threads' stacks
/// wait in `done` until a later start unmaps them.
enum Threads {
  static let stackSize = 256 * 1024

  final class Start {
    let body: @Sendable () -> Void
    let stack: UInt
    /// A handle to the thread, to see when it has ended.
    let thread: UInt32
    /// The thread's block, at its stack's top.
    let block: UInt
    init(body: @escaping @Sendable () -> Void, stack: UInt, thread: UInt32, block: UInt) {
      self.body = body
      self.stack = stack
      self.thread = thread
      self.block = block
    }
  }

  static let lock = Lock()
  nonisolated(unsafe) static var running: [(thread: UInt32, stack: UInt)] = []

  static func start(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) {
    reap()
    let vmo = try Kernel.vmoCreate(stackSize)
    defer { Kernel.close(vmo) }
    let stack = unsafe UInt(bitPattern: try Kernel.vmoMap(vmo, 0, stackSize, true))
    let watch: UInt32
    do throws(Status) {
      watch = try Kernel.duplicate(thread, .sameRights)
    } catch {
      unsafe Kernel.vmoUnmap(UnsafeMutableRawPointer(bitPattern: stack)!, stackSize)
      throw error
    }
    // The thread's block (LibSys.ThreadBlock) at the stack's top, zero as
    // the VMO is, and the stack below it. amd64 code expects to have been
    // called: its stack 8 off 16 at entry.
    let blockAt = stack + UInt(stackSize - ThreadBlock.size)
    #if arch(x86_64)
      let top = UInt64(blockAt) - 8
    #else
      let top = UInt64(blockAt)
    #endif
    let start = Start(body: body, stack: stack, thread: watch, block: blockAt)
    let arg = UInt64(UInt(bitPattern: unsafe Unmanaged.passRetained(start).toOpaque()))
    let entry: @convention(c) (UInt64, UInt64) -> Void = td_thread_entry
    let r = sys(Number.threadStart, UInt64(thread), UInt64(UInt(bitPattern: unsafe unsafeBitCast(entry, to: UnsafeRawPointer.self))),
                top, arg, 0)
    if r < 0 {
      unsafe Unmanaged<Start>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(arg))!).release()
      Kernel.close(watch)
      unsafe Kernel.vmoUnmap(UnsafeMutableRawPointer(bitPattern: stack)!, stackSize)
      try check(r)
    }
    lock.withLock { running.append((watch, stack)) }
  }

  /// Unmaps the stacks of threads that have ended.
  static func reap() {
    let ended = lock.withLock { () -> [(thread: UInt32, stack: UInt)] in
      var ended: [(thread: UInt32, stack: UInt)] = []
      running.removeAll { t in
        let over = (try? Kernel.wait(t.thread, Signals.terminated, 0)).map { $0 & Signals.terminated != 0 } ?? false
        if over { ended.append(t) }
        return over
      }
      return ended
    }
    for t in ended {
      Kernel.close(t.thread)
      unsafe Kernel.vmoUnmap(UnsafeMutableRawPointer(bitPattern: t.stack)!, stackSize)
    }
  }
}

/// Where a thread Sys started begins: on its own stack, with its Start.
@c func td_thread_entry(_ arg: UInt64, _ unused: UInt64) {
  let start = unsafe Unmanaged<Threads.Start>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(arg))!).takeRetainedValue()
  unsafe ThreadBlock.install(UnsafeMutableRawPointer(bitPattern: start.block)!, thread: start.thread)
  start.body()
  _ = consume start
  _ = sys(Number.threadExit, 0)
  while true {}
}
