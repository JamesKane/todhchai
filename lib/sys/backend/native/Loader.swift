// SPDX-License-Identifier: BSD-3-Clause

// Starting a process from a program image (M3d), as croi's userboot does:
// the ELF's read-only segments are mapped straight from the image's VMO
// (bootfs), the others copied into VMOs of their own, a stack is mapped
// as PT_GNU_STACK asks, and the first thread starts at the entry with a
// bootstrap channel whose one message is processargs (Zircon's, croi's
// processargs.h). The process is given its own process, thread and root
// VMAR, a debuglog for stdout, and the caller's handle as PA_USER0: the
// launcher's Startup channel. Nothing else: no job, no resource, no bootfs.

import Elf
import LibSys

/// A program's entry, natively: an ELF file in a VMO (bootfs), which the
/// caller keeps open while processes start from it.
public struct ProgramEntry: Sendable {
  /// The VMO, borrowed.
  public let image: UInt32
  public let offset: Int
  public let length: Int
  /// Its argv[0].
  public let name: String

  public init(image: UInt32, offset: Int, length: Int, name: String) {
    self.image = image
    self.offset = offset
    self.length = length
    self.name = name
  }
}

enum Loader {
  /// CROI_VM_* (croi's task.h).
  static let read: UInt32 = 1, write: UInt32 = 2, execute: UInt32 = 4, specific: UInt32 = 1 << 4
  static let defaultStack: UInt64 = 256 * 1024

  #if arch(x86_64)
    static let machine = ElfImage.Machine.amd64
  #elseif arch(arm64)
    static let machine = ElfImage.Machine.arm64
  #else
    static let machine = ElfImage.Machine.rv64
  #endif

  /// Root VMARs of processes made and not yet started, by the process's
  /// koid (a handle's number may be reused; a koid never is).
  nonisolated(unsafe) static var vmars: [(koid: UInt64, vmar: UInt32)] = []
  static let lock = Lock()

  static func keep(_ process: UInt32, vmar: UInt32) {
    guard let koid = try? Kernel.info(process).koid else {
      Kernel.close(vmar)
      return
    }
    lock.withLock { vmars.append((koid, vmar)) }
  }

  static func take(_ process: UInt32) throws(Status) -> UInt32 {
    let koid = try Kernel.info(process).koid
    let vmar = lock.withLock { () -> UInt32? in
      guard let i = vmars.firstIndex(where: { $0.koid == koid }) else { return nil }
      return vmars.remove(at: i).vmar
    }
    guard let vmar else { throw .badState }  // started already, or not made here
    return vmar
  }

  /// Loads `program` into `process` and starts `thread` there, handing it
  /// `arg`. `arg` is consumed whatever happens.
  static func start(_ process: UInt32, _ thread: UInt32, _ arg: UInt32, _ program: ProgramEntry,
                    _ extra: [(info: UInt32, handle: UInt32)]) throws(Status) {
    var handles: [UInt32] = [arg] + extra.map { $0.handle }
    defer { for h in handles { Kernel.close(h) } }
    let vmar = try take(process)
    handles.append(vmar)

    let elf = try image(program)
    guard elf.kind == .executable else { throw .notSupported }  // PIE: not yet
    let region = try out(InlineArray<2, UInt64>(repeating: 0)) { sys(Number.objectGetInfo, UInt64(vmar), 7, $0, 16) }
    for s in elf.segments { try load(s, program, vmar: vmar, base: region[0]) }

    let stackSize = UInt64(Kernel.pages(Int(elf.stackSize ?? defaultStack)))
    let stack = try Kernel.vmoCreate(Int(stackSize))
    let stackBase = try map(vmar, read | write, 0, stack, 0, stackSize)
    Kernel.close(stack)  // the mapping keeps it

    // Its own handles, its stdout, and the caller's.
    let processCopy = try Kernel.duplicate(process, .sameRights)
    handles.append(processCopy)
    let threadCopy = try Kernel.duplicate(thread, .sameRights)
    handles.append(threadCopy)
    let log = try out(UInt32(0)) { sys(Number.debuglogCreate, 0, 0, $0) }
    handles.append(log)
    let infos = [ProcessArgs.info(ProcessArgs.user0)] + extra.map { $0.info } + [
      ProcessArgs.info(ProcessArgs.vmarRoot),
      ProcessArgs.info(ProcessArgs.processSelf), ProcessArgs.info(ProcessArgs.threadSelf),
      ProcessArgs.info(ProcessArgs.fd, 1),
    ]
    let ends = try Kernel.channelCreate()
    defer { Kernel.close(ends.0) }
    let given = handles
    handles = []  // the write takes them, written or not
    try Kernel.channelWrite(ends.0, processArgs(infos, name: program.name), given)
    // process_start takes the bootstrap end, started or not (Zircon's rule).
    try check(sys(Number.processStart, UInt64(process), UInt64(thread), elf.entry, stackBase + stackSize,
                  UInt64(ends.1), 0))
  }

  /// The program's headers, read from its VMO.
  static func image(_ program: ProgramEntry) throws(Status) -> ElfImage {
    var count = min(program.length, 4096)
    while true {
      let header = try Kernel.vmoRead(program.image, program.offset, count)
      do throws(ElfImage.Error) {
        return try ElfImage(header: header, fileSize: program.length, machine: machine)
      } catch .needs(let more) where more > count {
        count = more
      } catch {
        throw .invalidArgs
      }
    }
  }

  /// Maps one PT_LOAD segment: all file and read-only, from the image's
  /// pages; otherwise copied into a VMO of its own.
  static func load(_ s: ElfImage.Segment, _ program: ProgramEntry, vmar: UInt32, base: UInt64) throws(Status) {
    guard s.memsz > 0 else { return }
    let page = UInt64(Kernel.pageSize)
    let start = s.vaddr & ~(page - 1), lead = s.vaddr - start
    let size = UInt64(Kernel.pages(Int(lead + s.memsz)))
    guard start >= base else { throw .invalidArgs }
    var options: UInt32 = specific
    if s.readable { options |= read }
    if s.writable { options |= write }
    if s.executable { options |= execute }
    let fileStart = UInt64(program.offset) + s.offset - lead
    if !s.writable, s.filesz == s.memsz, fileStart % page == 0 {
      _ = try map(vmar, options, start - base, program.image, fileStart, size)
      return
    }
    let vmo = try Kernel.vmoCreate(Int(size))
    defer { Kernel.close(vmo) }  // the mapping keeps it
    // Copied a piece at a time: a data segment may be large.
    var done: UInt64 = 0
    while done < s.filesz {
      let n = Int(min(s.filesz - done, 64 * 1024))
      let bytes = try Kernel.vmoRead(program.image, program.offset + Int(s.offset + done), n)
      try Kernel.vmoWrite(vmo, Int(lead + done), bytes)
      done += UInt64(n)
    }
    _ = try map(vmar, options, start - base, vmo, 0, size)
  }

  /// vmar_map: the VMAR and its options share the first argument.
  static func map(_ vmar: UInt32, _ options: UInt32, _ offset: UInt64, _ vmo: UInt32, _ vmoOffset: UInt64,
                  _ length: UInt64) throws(Status) -> UInt64
  {
    try out(UInt64(0)) {
      sys(Number.vmarMap, UInt64(vmar) | UInt64(options) << 32, offset, UInt64(vmo), vmoOffset, length, $0)
    }
  }

  /// processargs: the header, a handle-info word a handle, argv (the name
  /// alone), no environment.
  static func processArgs(_ infos: [UInt32], name: String) -> [UInt8] {
    var m: [UInt8] = []
    func put(_ v: UInt32) { for shift in [0, 8, 16, 24] as [UInt32] { m.append(UInt8(truncatingIfNeeded: v >> shift)) } }
    let header: UInt32 = 36
    let args = header + 4 * UInt32(infos.count)
    let environment = args + UInt32(name.utf8.count + 1)
    put(ProcessArgs.protocolMagic)
    put(ProcessArgs.version)
    put(header)  // handle_info_off
    put(args)  // args_off
    put(1)  // args_num
    put(environment)  // environ_off
    put(0)  // environ_num
    put(0)  // names_off
    put(0)  // names_num
    for i in infos { put(i) }
    m.append(contentsOf: name.utf8)
    m.append(0)
    return m
  }
}
