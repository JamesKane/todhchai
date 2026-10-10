// SPDX-License-Identifier: BSD-3-Clause

// A recording on croi (M3f): croi's kernel rings and a region per traced
// process, read back as one trace. The session starts croi's kernel trace
// (trace_configure, with the tracing or root resource), makes each
// process's region (a VMO with the header written, given to the process
// as processargs' PA_USER1: `region(for:)`), and when the recording ends
// writes every region and the kernel's rings out as `.trace` files
// (docs/trace-format.md), compacted to what was written.
//
// Getting them out of the guest: croi has no device to the host before
// virtio (M3h), so `export` prints each file in base64 over the debuglog,
// one line a record:
//
//     td-trace NAME OFFSET BASE64     (120 bytes a line)
//     td-trace NAME OFFSET zero COUNT (a run of zeros)
//     td-trace NAME end SIZE
//
// paced to the console (see `perLine`), and `td boot` reassembles them from the console (bench/out/boot/<arch>/
// trace). Slow (paced to the console, below), but the recordings are small
// and it needs nothing croi doesn't have. The kernel's file is `kernel.trace`: process 0, a ring a
// CPU, no names.
//
// Thread ids: croi names a thread by its process's internal task id and
// index, which user space can't read yet, so a region's process id is
// 0xF0000 + its number here; records join the kernel's through flow ids.

import LibSys
import TDNative
import Sys
import TraceFormat

public final class TraceSession {
  /// croi's trace_configure (syscall 50) and its ops.
  static let configure: UInt64 = 50
  static let opStart: UInt64 = 0, opStop: UInt64 = 1, opRings: UInt64 = 4
  /// croi's kernel categories (trace.h).
  public enum Kernel {
    public static let sched: UInt32 = 1 << 0
    public static let irq: UInt32 = 1 << 1
    public static let vm: UInt32 = 1 << 2
    public static let ipc: UInt32 = 1 << 3
    public static let futex: UInt32 = 1 << 4
    public static let syscall: UInt32 = 1 << 5
  }

  static let stringsSize = 64 * 1024
  static let rings = 16
  static let recordsPerRing = 8192
  static let kernelPageSize = 4096

  let resource: UInt32
  let categories: TraceCategory
  public let counterHz: UInt64
  public let start: UInt64
  /// A handle the session keeps (arrays can't hold a `Handle`).
  final class Held {
    let handle: Handle
    init(_ handle: consuming Handle) { self.handle = handle }
  }

  /// Each CPU's ring: read-only VMOs.
  var kernelRings: [Held] = []
  /// Each region made, and its owner's name.
  var regions: [(name: String, vmo: Held)] = []
  var stopped = false

  /// Starts croi's kernel trace (`kernel`, a mask of `Kernel` categories,
  /// `pagesPerCPU` pages of records a CPU, oneshot) and a session whose
  /// regions record `categories`. `resource`: the tracing or root resource,
  /// borrowed.
  public init(resource: UInt32, categories: TraceCategory, kernel: UInt32, pagesPerCPU: Int = 256) throws(Status) {
    self.resource = resource
    self.categories = categories
    try Self.check(unsafe td_syscall6(Self.configure, UInt64(resource), Self.opStart, UInt64(kernel),
                                      UInt64(pagesPerCPU), 0, 0))
    var handles = InlineArray<64, UInt32>(repeating: 0)
    let count = unsafe withUnsafeMutablePointer(to: &handles) { p in
      unsafe td_syscall6(Self.configure, UInt64(resource), Self.opRings, UInt64(UInt(bitPattern: p)), 64, 0, 0)
    }
    try Self.check(count)
    for i in 0..<Int(count) { kernelRings.append(Held(Handle(raw: handles[i]))) }
    guard let first = kernelRings.first else { throw .badState }
    let header = try VMO.read(first.handle, offset: 0, count: 64)
    counterHz = Self.u64(header, TraceFormat.ringFrequency)
    start = Self.u64(header, TraceFormat.ringSession)
  }

  static func check(_ r: Int64) throws(Status) {
    if r < 0 { throw Status(rawValue: Int32(truncatingIfNeeded: r)) ?? .internal }
  }

  /// A new region for the process `name`: a handle to move into it, with
  /// its processargs info word (`Launcher.extraStartupHandles`). The
  /// session keeps its own.
  public func region(for name: String) -> (info: UInt32, handle: UInt32)? {
    guard !stopped else { return nil }
    let capacity = Self.recordsPerRing
    let ringSize = TraceFormat.ringHeaderSize + capacity * TraceFormat.recordSize
    let size = TraceFormat.headerSize + Self.stringsSize + Self.rings * ringSize
    do throws(Status) {
      let vmo = try VMO.create(size: size)
      var h = [UInt8](repeating: 0, count: 96)
      Self.put(&h, TraceFormat.regionMagic, 0)
      Self.put(&h, TraceFormat.version, 4)
      Self.put(&h, counterHz, TraceFormat.counterHz)
      Self.put(&h, start, TraceFormat.start)
      Self.put(&h, UInt32(0xF0000 + regions.count + 1), TraceFormat.processID)
      Self.put(&h, UInt32(Self.rings), TraceFormat.ringCount)
      Self.put(&h, UInt64(ringSize), TraceFormat.ringSize)
      Self.put(&h, UInt64(TraceFormat.headerSize), TraceFormat.stringsOffset)
      Self.put(&h, UInt64(Self.stringsSize), TraceFormat.stringsSize)
      Self.put(&h, UInt64(TraceFormat.headerSize + Self.stringsSize), TraceFormat.ringsOffset)
      Self.put(&h, categories.rawValue, TraceFormat.categories)
      try VMO.write(vmo, offset: 0, h)
      let theirs = try vmo.duplicate()
      regions.append((name, Held(vmo)))
      return (ProcessArgs.info(ProcessArgs.traceRegion), theirs.release())
    } catch {
      return nil
    }
  }

  /// Ends the recording: the kernel's, and the regions' (their categories
  /// cleared, so processes still running stop writing).
  public func stop() {
    guard !stopped else { return }
    stopped = true
    _ = unsafe td_syscall6(Self.configure, UInt64(resource), Self.opStop, 0, 0, 0, 0)
    for r in regions { try? VMO.write(r.vmo.handle, offset: TraceFormat.categories, [UInt8](repeating: 0, count: 8)) }
  }

  // MARK: Export

  /// Stops, then writes every file through `line` (export's lines, above).
  public func export(_ line: (String) -> Void) {
    stop()
    var files: [(name: String, bytes: [UInt8])] = []
    if let k = try? kernelFile() { files.append(("kernel", k)) }
    for (i, r) in regions.enumerated() {
      if let bytes = try? regionFile(r.vmo) { files.append(("\(i + 1)-\(r.name)", bytes)) }
    }
    for f in files { emit(f.name, f.bytes, line) }
  }

  /// The time a line is given: croi's debuglog has no flow control, and
  /// drops records when its console dumper falls 512 behind ("dlog: N
  /// records dropped"). The console drains about half a line a millisecond
  /// under KVM (each byte to the UART is an exit; M3f measured ~110 KB/s),
  /// so the export goes slower than that, and a dropped line shows in `td
  /// boot` as a missing piece. Keep recordings small.
  static let perLine: Int64 = 2_500_000

  func emit(_ name: String, _ bytes: [UInt8], _ line: (String) -> Void) {
    var at = 0, lines = 0
    while at < bytes.count {
      // A run of zeros (the header, rings' padding) is one line.
      var zeros = 0
      while at + zeros < bytes.count && bytes[at + zeros] == 0 { zeros += 1 }
      if zeros >= 120 {
        line("td-trace \(name) \(at) zero \(zeros)")
        at += zeros
      } else {
        let n = min(120, bytes.count - at)
        line("td-trace \(name) \(at) \(Self.base64(bytes[at..<(at + n)]))")
        at += n
      }
      lines += 1
      sleep(until: Clock.monotonic() + Self.perLine)
    }
    line("td-trace \(name) end \(bytes.count)")
  }

  /// A process's region, compacted: the strings used, and each claimed ring
  /// with its records in order from the start.
  func regionFile(_ held: Held) throws(Status) -> [UInt8] {
    let header = try VMO.read(held.handle, offset: 0, count: TraceFormat.headerSize)
    let used = min(Int(Self.u64(header, TraceFormat.stringsUsed)), Self.stringsSize)
    let strings = try VMO.read(held.handle, offset: Int(Self.u64(header, TraceFormat.stringsOffset)), count: used)
    let claimed = min(Int(Self.u32(header, TraceFormat.ringsClaimed)), Int(Self.u32(header, TraceFormat.ringCount)))
    let ringsAt = Int(Self.u64(header, TraceFormat.ringsOffset)), ringSize = Int(Self.u64(header, TraceFormat.ringSize))
    var rings: [(header: [UInt8], records: [UInt8])] = []
    for i in 0..<claimed {
      let at = ringsAt + i * ringSize
      let ringHeader = try VMO.read(held.handle, offset: at, count: TraceFormat.ringHeaderSize)
      let count = Int(min(Self.u64(ringHeader, TraceFormat.ringHead), Self.u64(ringHeader, TraceFormat.ringCapacity)))
      let records = try VMO.read(held.handle, offset: at + TraceFormat.ringHeaderSize, count: count * TraceFormat.recordSize)
      rings.append((ringHeader, records))
    }
    var file = header
    return Self.assemble(&file, strings: strings, rings: rings)
  }

  /// The kernel's rings as a region: process 0, no strings, a ring a CPU.
  func kernelFile() throws(Status) -> [UInt8] {
    var rings: [(header: [UInt8], records: [UInt8])] = []
    for held in kernelRings {
      var header = try VMO.read(held.handle, offset: 0, count: 64)
      let count = Int(min(Self.u64(header, TraceFormat.ringHead), Self.u64(header, TraceFormat.ringCapacity)))
      let records = try VMO.read(held.handle, offset: Self.kernelPageSize, count: count * TraceFormat.recordSize)
      header += [UInt8](repeating: 0, count: TraceFormat.ringHeaderSize - 64)
      Self.put(&header, TraceFormat.ringMagic, TraceFormat.ringMagicOffset)
      rings.append((header, records))
    }
    var file = [UInt8](repeating: 0, count: TraceFormat.headerSize)
    Self.put(&file, TraceFormat.regionMagic, 0)
    Self.put(&file, TraceFormat.version, 4)
    Self.put(&file, counterHz, TraceFormat.counterHz)
    Self.put(&file, start, TraceFormat.start)
    return Self.assemble(&file, strings: [], rings: rings)
  }

  /// `header` with the layout rewritten for `strings` and `rings`, each ring
  /// holding its records from 0 at a capacity that fits them all.
  static func assemble(_ header: inout [UInt8], strings: [UInt8], rings: [(header: [UInt8], records: [UInt8])])
    -> [UInt8]
  {
    var capacity = 1
    for r in rings { while capacity < r.records.count / TraceFormat.recordSize { capacity <<= 1 } }
    let ringSize = TraceFormat.ringHeaderSize + capacity * TraceFormat.recordSize
    let stringsSize = (strings.count + 3) & ~3
    put(&header, UInt32(rings.count), TraceFormat.ringCount)
    put(&header, UInt32(rings.count), TraceFormat.ringsClaimed)
    put(&header, UInt64(ringSize), TraceFormat.ringSize)
    put(&header, UInt64(TraceFormat.headerSize), TraceFormat.stringsOffset)
    put(&header, UInt64(stringsSize), TraceFormat.stringsSize)
    put(&header, UInt64(strings.count), TraceFormat.stringsUsed)
    put(&header, UInt64(TraceFormat.headerSize + stringsSize), TraceFormat.ringsOffset)
    var file = header
    file += strings
    file += [UInt8](repeating: 0, count: stringsSize - strings.count)
    for r in rings {
      var h = r.header
      put(&h, UInt64(r.records.count / TraceFormat.recordSize), TraceFormat.ringHead)
      put(&h, UInt64(capacity), TraceFormat.ringCapacity)
      put(&h, UInt32(0), TraceFormat.ringMode)  // read from the start: no wrap
      file += h
      file += r.records
      file += [UInt8](repeating: 0, count: capacity * TraceFormat.recordSize - r.records.count)
    }
    return file
  }

  // MARK: Bytes

  static func put<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ v: T, _ at: Int) {
    for i in 0..<MemoryLayout<T>.size { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
  }

  static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[at + i]) << (8 * i) }
    return v
  }

  static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(truncatingIfNeeded: u64(b + [0, 0, 0, 0], at)) }

  static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

  /// RFC 4648 base64, padded.
  static func base64(_ bytes: ArraySlice<UInt8>) -> String {
    var out: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
      let n = min(3, bytes.endIndex - i)
      var v = UInt32(bytes[i]) << 16
      if n > 1 { v |= UInt32(bytes[i + 1]) << 8 }
      if n > 2 { v |= UInt32(bytes[i + 2]) }
      out.append(alphabet[Int(v >> 18 & 63)])
      out.append(alphabet[Int(v >> 12 & 63)])
      out.append(n > 1 ? alphabet[Int(v >> 6 & 63)] : UInt8(ascii: "="))
      out.append(n > 2 ? alphabet[Int(v & 63)] : UInt8(ascii: "="))
      i += n
    }
    return String(decoding: out, as: UTF8.self)
  }
}
