// SPDX-License-Identifier: BSD-3-Clause

// libsys: what a native tier 0 process runs before and after its `main`
// (M3, decided: ours, not croi's runtime). _start (entry/<arch>.S) calls
// td_start with the bootstrap channel, whose one message is Zircon's
// processargs (croi's processargs.h): a header, a handle-info word per
// handle, then the argument and environment strings. td_start keeps the
// handles for `StartupHandles.take`, sets up stdout and the heap, and runs
// the program's main.

import TDNative

/// croi's system call numbers that libsys uses (croi's syscall.h).
enum SyscallNumber {
  static let clockMonotonic: UInt64 = 3
  static let handleClose: UInt64 = 10
  static let vmoCreate: UInt64 = 40
  static let processExit: UInt64 = 63
  static let vmarMap: UInt64 = 71
  static let vmarUnmap: UInt64 = 72
  static let channelRead: UInt64 = 82
  static let futexWait: UInt64 = 90
  static let futexWake: UInt64 = 91
  static let debuglogWrite: UInt64 = 111
}

/// What the runtime keeps for Sys (lib/sys/backend/native): this process's
/// handle and its root VMAR, and the vDSO's clock.
public enum Runtime {
  nonisolated(unsafe) public internal(set) static var processSelf: UInt32 = 0
  nonisolated(unsafe) public internal(set) static var vmarRoot: UInt32 = 0
  /// The main thread's own handle.
  nonisolated(unsafe) public internal(set) static var threadSelf: UInt32 = 0
  nonisolated(unsafe) static var vdsoClock: (@convention(c) () -> UInt64)? = nil

  /// Nanoseconds on the monotonic clock: the vDSO's, with no kernel call,
  /// or the system call if the vDSO isn't there.
  public static func monotonic() -> Int64 {
    if let clock = unsafe vdsoClock { return Int64(bitPattern: clock()) }
    return unsafe td_syscall6(SyscallNumber.clockMonotonic, 0, 0, 0, 0, 0, 0)
  }

  /// The vDSO's header (croi's shared.h): magic, version, then each
  /// function's offset from the header.
  static func findClock(_ base: UInt64) {
    guard base != 0, let header = unsafe UnsafeRawPointer(bitPattern: UInt(base)) else { return }
    let magic = unsafe header.load(as: UInt32.self)
    let version = unsafe header.load(fromByteOffset: 4, as: UInt32.self)
    guard magic == 0x5344_5643, version >= 1 else { return }
    let offset = unsafe header.load(fromByteOffset: 8, as: UInt32.self)
    unsafe vdsoClock = unsafe unsafeBitCast(header + Int(offset), to: (@convention(c) () -> UInt64).self)
  }
}

/// processargs' constants (croi's processargs.h, Zircon's values).
public enum ProcessArgs {
  public static let protocolMagic: UInt32 = 0x4150_585d
  public static let version: UInt32 = 0x0001_000

  /// Handle types: the low byte of a handle-info word.
  public static let processSelf: UInt32 = 0x01
  public static let threadSelf: UInt32 = 0x02
  public static let jobDefault: UInt32 = 0x03
  public static let vmarRoot: UInt32 = 0x04
  public static let vmoBootfs: UInt32 = 0x1B
  public static let fd: UInt32 = 0x30
  public static let resource: UInt32 = 0x3F
  public static let user0: UInt32 = 0xF0
  /// Todhchai's: the process's trace region, a VMO (lib/trace, M3f).
  public static let traceRegion: UInt32 = 0xF1

  /// A handle-info word: the type, and an argument in bits 16-31.
  public static func info(_ type: UInt32, _ argument: UInt32 = 0) -> UInt32 {
    (type & 0xFF) | (argument & 0xFFFF) << 16
  }
}

/// The handles the process was started with, by their processargs info.
public enum StartupHandles {
  nonisolated(unsafe) static var entries: [(info: UInt32, handle: UInt32)] = []

  /// The handle started with `info`, which is the caller's from then on;
  /// nil if there was none or it was taken.
  public static func take(_ info: UInt32) -> UInt32? {
    guard let i = entries.firstIndex(where: { $0.info == info && $0.handle != 0 }) else { return nil }
    let handle = entries[i].handle
    entries[i].handle = 0
    return handle
  }

  /// The info words of the handles not yet taken.
  public static var remaining: [UInt32] { entries.filter { $0.handle != 0 }.map { $0.info } }
}

/// The arguments the process was started with, its name first (Embedded
/// Swift has no CommandLine).
public enum Arguments {
  nonisolated(unsafe) public internal(set) static var strings: [String] = []
}

/// The environment the process was started with (`name=value` strings).
public enum Environment {
  nonisolated(unsafe) public internal(set) static var strings: [String] = []

  /// The value of `name`, if the environment has it.
  public static func value(_ name: String) -> String? {
    for s in strings {
      let bytes = Array(s.utf8)
      if bytes.count > name.utf8.count, bytes[name.utf8.count] == UInt8(ascii: "="),
        bytes[0..<name.utf8.count].elementsEqual(name.utf8)
      {
        return String(decoding: bytes[(name.utf8.count + 1)...], as: UTF8.self)
      }
    }
    return nil
  }
}

/// Ends the process with `code`, after writing what stdout holds.
public func exit(_ code: Int64) -> Never {
  Stdout.flush()
  _ = unsafe td_syscall6(SyscallNumber.processExit, UInt64(bitPattern: code), 0, 0, 0, 0, 0)
  while true {}
}

@c public func td_start(_ bootstrap: UInt64, _ arg2: UInt64, _ vdso: UInt64) -> Never {
  // The message is read onto the stack: the heap needs the root VMAR,
  // which is in it.
  var bytes = InlineArray<4096, UInt8>(repeating: 0)
  var handles = InlineArray<64, UInt32>(repeating: 0)
  var actual: UInt64 = 0
  let status = unsafe withUnsafeMutablePointer(to: &bytes) { b in
    unsafe withUnsafeMutablePointer(to: &handles) { h in
      unsafe withUnsafeMutablePointer(to: &actual) { a in
        unsafe td_syscall6(
          SyscallNumber.channelRead, bootstrap, 0, UInt64(UInt(bitPattern: b)), UInt64(UInt(bitPattern: h)),
          4096 | 64 << 32, UInt64(UInt(bitPattern: a)))
      }
    }
  }
  _ = unsafe td_syscall6(SyscallNumber.handleClose, bootstrap, 0, 0, 0, 0, 0)
  let size = status == 0 ? Int(actual & 0xFFFF_FFFF) : 0
  let count = status == 0 ? Int(actual >> 32) : 0

  func word(_ at: Int) -> UInt32 {
    guard at >= 0, at + 4 <= size else { return 0 }
    return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
  }
  let valid = size >= 36 && word(0) == ProcessArgs.protocolMagic && word(4) == ProcessArgs.version
    && Int(word(8)) + 4 * count <= size
  var infos: [UInt32] = []
  var vmar: UInt32 = 0
  var log: UInt32 = 0
  var thread: UInt32 = 0
  if valid {
    // Found before anything allocates.
    for i in 0..<count {
      let info = word(Int(word(8)) + 4 * i)
      if info == ProcessArgs.info(ProcessArgs.vmarRoot) && vmar == 0 { vmar = handles[i] }
      if info == ProcessArgs.info(ProcessArgs.fd, 1) && log == 0 { log = handles[i] }
      if info == ProcessArgs.info(ProcessArgs.threadSelf) && thread == 0 { thread = handles[i] }
    }
  }
  // The thread pointer first: the trace and locks may read it from here on.
  ThreadBlock.installMain(thread: thread)
  Heap.vmar = vmar
  Stdout.log = log
  Runtime.vmarRoot = vmar
  Runtime.findClock(vdso)

  var argv: [UnsafeMutablePointer<CChar>?] = unsafe []
  if valid {
    for i in 0..<count { infos.append(word(Int(word(8)) + 4 * i)) }
    // NUL-terminated strings from `offset`, at most `number` of them.
    func strings(_ offset: UInt32, _ number: UInt32) -> [[UInt8]] {
      var out: [[UInt8]] = []
      var at = Int(offset)
      while out.count < Int(number) && at < size {
        var s: [UInt8] = []
        while at < size && bytes[at] != 0 {
          s.append(bytes[at])
          at += 1
        }
        out.append(s)
        at += 1
      }
      return out
    }
    let args = strings(word(12), word(16))
    Arguments.strings = args.map { String(decoding: $0, as: UTF8.self) }
    for arg in args {
      let p = unsafe UnsafeMutablePointer<CChar>.allocate(capacity: arg.count + 1)
      for (j, b) in arg.enumerated() { unsafe p[j] = CChar(bitPattern: b) }
      unsafe p[arg.count] = 0
      unsafe argv.append(p)
    }
    Environment.strings = strings(word(20), word(24)).map { String(decoding: $0, as: UTF8.self) }
    for i in 0..<count where handles[i] != 0 {
      StartupHandles.entries.append((infos[i], handles[i]))
    }
  }
  // stdout, the root VMAR and the process's own handle stay the runtime's.
  _ = StartupHandles.take(ProcessArgs.info(ProcessArgs.fd, 1))
  _ = StartupHandles.take(ProcessArgs.info(ProcessArgs.vmarRoot))
  Runtime.processSelf = StartupHandles.take(ProcessArgs.info(ProcessArgs.processSelf)) ?? 0
  Runtime.threadSelf = StartupHandles.take(ProcessArgs.info(ProcessArgs.threadSelf)) ?? 0

  let argc = unsafe Int32(argv.count)
  unsafe argv.append(nil)
  let code = unsafe argv.withUnsafeMutableBufferPointer { unsafe main(argc, $0.baseAddress) }
  exit(Int64(code))
}

@c public func __stack_chk_fail() -> Never {
  Stdout.write("stack smashed: process ends\n")
  exit(-1)
}
