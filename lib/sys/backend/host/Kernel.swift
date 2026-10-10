// SPDX-License-Identifier: BSD-3-Clause

// Sys's calls on the hosted kernel (SysHost), for SwiftPM builds. The CMake
// build uses lib/sys/backend/stub until croi's syscalls (M3).

import Glibc
import SysHost

/// A program's entry, hosted: a Swift function given its startup handle.
public struct ProgramEntry: Sendable {
  let body: @Sendable (consuming Handle) -> Void
  public init(_ body: @escaping @Sendable (consuming Handle) -> Void) { self.body = body }
}

enum Kernel {
  static var k: HostKernel { HostKernel.shared }

  static func close(_ h: UInt32) { try? k.close(h) }
  static func duplicate(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 { try k.duplicate(h, rights: r) }
  static func replace(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 { try k.replace(h, rights: r) }
  static func info(_ h: UInt32) throws(Status) -> HandleInfo {
    let i = try k.info(h)
    return HandleInfo(koid: i.koid, rights: i.rights, type: i.type, relatedKoid: i.relatedKoid)
  }
  static func signal(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) { try k.signal(h, clear: clear, set: set) }
  static func signalPeer(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) {
    try k.signalPeer(h, clear: clear, set: set)
  }
  static func wait(_ h: UInt32, _ signals: UInt32, _ deadline: Int64) throws(Status) -> UInt32 {
    do {
      return try k.wait(h, for: signals, deadline: deadline)
    } catch {
      throw error.status
    }
  }
  static func waitAsync(_ h: UInt32, _ port: UInt32, _ key: UInt64, _ signals: UInt32, _ edge: Bool) throws(Status) {
    try k.waitAsync(h, port: port, key: key, signals: signals, edge: edge)
  }

  static func channelCreate() throws(Status) -> (UInt32, UInt32) { try k.channelCreate() }
  static func channelWrite(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32]) throws(Status) {
    try k.channelWrite(h, bytes: bytes, handles: handles)
  }
  static func channelRead(_ h: UInt32) throws(Status) -> Channel.Message {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    var handles = [UInt32](repeating: 0, count: 64)
    do {
      // Untyped closures: a `throws(E)` closure passed to these `rethrows`
      // methods miscompiles in Swift 6.4 (CLAUDE.md, "Toolchain pitfalls").
      let got = try unsafe bytes.withUnsafeMutableBytes { b in
        try unsafe handles.withUnsafeMutableBufferPointer { hb in
          try unsafe k.channelRead(h, bytes: b, handles: hb)
        }
      }
      return Channel.Message(bytes: Array(bytes[..<got.byteCount]), handles: Array(handles[..<got.handleCount]))
    } catch {
      throw (error as? HostKernel.ReadError)?.status ?? .invalidArgs
    }
  }
  static func channelCall(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32], _ deadline: Int64) throws(Status)
    -> Channel.Message
  {
    let m = try k.channelCall(h, bytes: bytes, handles: handles, deadline: deadline)
    return Channel.Message(bytes: m.bytes, handles: m.handles)
  }

  static func eventCreate() throws(Status) -> UInt32 { try k.eventCreate() }
  static func eventPairCreate() throws(Status) -> (UInt32, UInt32) { try k.eventPairCreate() }

  static func portCreate() throws(Status) -> UInt32 { try k.portCreate() }
  static func portQueue(_ p: UInt32, _ packet: Packet) throws(Status) { try k.portQueue(p, packet) }
  static func portWait(_ p: UInt32, _ deadline: Int64) throws(Status) -> Packet { try k.portWait(p, deadline: deadline) }
  static func portCancel(_ p: UInt32, _ source: UInt32, _ key: UInt64) throws(Status) {
    try k.portCancel(p, source: source, key: key)
  }

  static func vmoCreate(_ size: Int) throws(Status) -> UInt32 { try k.vmoCreate(size: size) }
  static func vmoSize(_ h: UInt32) throws(Status) -> Int { try k.vmoSize(h) }
  static func vmoRead(_ h: UInt32, _ offset: Int, _ count: Int) throws(Status) -> [UInt8] {
    try k.vmoRead(h, offset: offset, count: count)
  }
  static func vmoWrite(_ h: UInt32, _ offset: Int, _ bytes: [UInt8]) throws(Status) {
    try k.vmoWrite(h, offset: offset, bytes)
  }
  static func vmoMap(_ h: UInt32, _ offset: Int, _ length: Int, _ writable: Bool) throws(Status) -> UnsafeMutableRawPointer {
    try unsafe k.vmoMap(h, offset: offset, length: length, writable: writable)
  }
  static func vmoUnmap(_ address: UnsafeMutableRawPointer, _ length: Int) { try? unsafe k.vmoUnmap(address) }

  // Resources and physical memory: none hosted.
  static func vmoCreatePhysical(_ resource: UInt32, _ address: UInt64, _ size: Int) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func vmoSetCachePolicy(_ h: UInt32, _ policy: VMO.CachePolicy) throws(Status) { throw .notSupported }
  static func resourceCreate(_ parent: UInt32, _ options: UInt32, _ base: UInt64, _ size: UInt64, _ name: String)
    throws(Status) -> UInt32
  { throw .notSupported }
  static func resourceInfo(_ h: UInt32) throws(Status) -> ResourceInfo { throw .notSupported }
  static func ioportsRequest(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) { throw .notSupported }
  static func ioportsRelease(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) { throw .notSupported }
  /// No ports: reads see what a missing device gives, all ones.
  static func portIn(_ port: UInt16, _ width: Int) -> UInt32 { UInt32.max >> (32 - 8 * width) }
  static func portOut(_ port: UInt16, _ width: Int, _ value: UInt32) {}

  static func debuglogCreate(_ resource: UInt32, readable: Bool) throws(Status) -> UInt32 { throw .notSupported }
  static func debuglogRead(_ h: UInt32) throws(Status) -> Debuglog.Record { throw .notSupported }
  static func portCreate(options: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func interruptCreate(_ resource: UInt32, _ number: UInt32, _ options: UInt32) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func interruptBind(_ h: UInt32, _ port: UInt32, _ key: UInt64) throws(Status) { throw .notSupported }
  static func interruptAck(_ h: UInt32) throws(Status) { throw .notSupported }
  static func interruptWait(_ h: UInt32) throws(Status) -> Int64 { throw .notSupported }
  static func interruptTrigger(_ h: UInt32, _ timestamp: Int64) throws(Status) { throw .notSupported }
  static func interruptSetAffinity(_ h: UInt32, _ cpus: UInt64) throws(Status) { throw .notSupported }
  static func iommuCreateStub(_ resource: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func btiCreate(_ iommu: UInt32, _ id: UInt64) throws(Status) -> UInt32 { throw .notSupported }
  static func btiSetProperties(_ bti: UInt32, _ p: DMA.Properties) throws(Status) { throw .notSupported }
  static func vmoCreateContiguous(_ bti: UInt32, _ size: Int, _ alignmentLog2: UInt32) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func btiPin(_ bti: UInt32, _ vmo: UInt32, _ offset: Int, _ size: Int, _ options: UInt32, _ count: Int)
    throws(Status) -> (pmt: UInt32, addresses: [UInt64])
  { throw .notSupported }
  static func pmtUnpin(_ pmt: UInt32) throws(Status) { throw .notSupported }
  static func btiReleaseQuarantine(_ bti: UInt32) throws(Status) { throw .notSupported }
  static func processSelf() throws(Status) -> UInt32 { try k.processSelf() }
  static func realtime() -> Int64 {
    var ts = timespec()
    unsafe clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }
  static func futexWait(_ address: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64) throws(Status) {
    try unsafe k.futexWait(address, current: current, deadline: deadline)
  }
  static func futexWake(_ address: UnsafeMutablePointer<UInt32>, count: Int) { unsafe k.futexWake(address, count: count) }

  static func timerCreate() throws(Status) -> UInt32 { try k.timerCreate() }
  static func timerSet(_ h: UInt32, _ deadline: Int64) throws(Status) { try k.timerSet(h, deadline: deadline) }
  static func timerCancel(_ h: UInt32) throws(Status) { try k.timerCancel(h) }

  static func jobCreate(_ parent: UInt32) throws(Status) -> UInt32 { try k.jobCreate(parent: parent) }
  static func processCreate(_ job: UInt32, _ name: String) throws(Status) -> UInt32 { try k.processCreate(job: job, name: name) }
  static func threadCreate(_ process: UInt32) throws(Status) -> UInt32 { try k.threadCreate(process: process) }
  static func processStart(_ process: UInt32, _ thread: UInt32, _ arg: UInt32, _ entry: ProgramEntry,
                           _ extra: [(info: UInt32, handle: UInt32)]) throws(Status) {
    for e in extra { close(e.handle) }  // hosted, a process's startup is `arg`
    try k.threadStart(thread, arg: arg) { raw in entry.body(Handle(raw: raw)) }
  }
  static func threadStart(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) {
    try k.threadStart(thread) { _ in body() }
  }
  static func kill(_ h: UInt32) throws(Status) { try k.kill(h) }
  static func exit(_ code: Int64) -> Never { k.exit(code: code) }
  static func processInfo(_ h: UInt32) throws(Status) -> ProcessInfo {
    let i = try k.processInfo(h)
    return ProcessInfo(returnCode: i.returnCode, started: i.started, exited: i.exited)
  }

  static func now() -> Int64 { HostKernel.now() }
  static func sleep(_ deadline: Int64) { k.sleep(until: deadline) }
}

extension Job {
  /// The root job, for the hosted boot (natively, userboot passes it to
  /// the launcher).
  public static func root() throws(Status) -> Handle { Handle(raw: try HostKernel.shared.rootJobHandle()) }
}
