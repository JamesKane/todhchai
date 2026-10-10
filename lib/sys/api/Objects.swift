// SPDX-License-Identifier: BSD-3-Clause

/// Channels: two ends, messages of bytes and handles.
public enum Channel {
  public static let maxBytes = 65_536
  public static let maxHandles = 64

  public static func create() throws(Status) -> Ends {
    let (a, b) = try Kernel.channelCreate()
    return Ends(a: Handle(raw: a), b: Handle(raw: b))
  }

  /// A message read from a channel; its handles are now this process's.
  public struct Message: Sendable {
    public var bytes: [UInt8]
    public var handles: [UInt32]
    public init(bytes: [UInt8], handles: [UInt32]) {
      self.bytes = bytes
      self.handles = handles
    }
  }

  /// Writes a message, moving `handles` into it (they are consumed even on
  /// failure).
  public static func write(_ channel: borrowing Handle, bytes: [UInt8], handles: [UInt32] = []) throws(Status) {
    try Kernel.channelWrite(channel.raw, bytes, handles)
  }

  /// Reads the next message, or throws `shouldWait` if there is none.
  public static func read(_ channel: borrowing Handle) throws(Status) -> Message {
    try Kernel.channelRead(channel.raw)
  }

  /// channel_call: writes the message (its first four bytes become the
  /// kernel's txid) and waits until `deadline` for the reply that echoes
  /// it, which comes to this caller alone.
  public static func call(_ channel: borrowing Handle, bytes: [UInt8], handles: [UInt32] = [],
                          deadline: Int64 = infiniteDeadline) throws(Status) -> Message
  {
    try Kernel.channelCall(channel.raw, bytes, handles, deadline)
  }
}

/// An event: a signal anyone holding it may set or clear.
public enum Event {
  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.eventCreate()) }
}

/// An eventpair: two events, each end signalling the other, and seeing
/// PEER_CLOSED when the other goes.
public enum EventPair {
  public static func create() throws(Status) -> Ends {
    let (a, b) = try Kernel.eventPairCreate()
    return Ends(a: Handle(raw: a), b: Handle(raw: b))
  }
}

/// Ports: where packets queue, from users and from wait_async.
public enum Port {
  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.portCreate()) }

  /// A port interrupts may be bound to (croi's PORT_BIND_TO_INTERRUPT).
  public static func create(bindToInterrupt: Bool) throws(Status) -> Handle {
    bindToInterrupt ? Handle(raw: try Kernel.portCreate(options: 1)) : try create()
  }

  /// Queues a user packet.
  public static func queue(_ port: borrowing Handle, _ packet: Packet) throws(Status) {
    try Kernel.portQueue(port.raw, packet)
  }

  /// The next packet, waiting until `deadline` for one.
  public static func wait(_ port: borrowing Handle, deadline: Int64 = infiniteDeadline) throws(Status) -> Packet {
    try Kernel.portWait(port.raw, deadline)
  }

  /// Cancels `source`'s wait_asyncs to the port with `key`, and their queued packets.
  public static func cancel(_ port: borrowing Handle, source: borrowing Handle, key: UInt64) throws(Status) {
    try Kernel.portCancel(port.raw, source.raw, key)
  }
}

/// Virtual memory objects: memory that handles share.
public enum VMO {
  /// How a VMO's mappings are cached (vmo_set_cache_policy).
  public enum CachePolicy: UInt32, Sendable {
    case cached = 0
    case uncached = 1
    case uncachedDevice = 2
    case writeCombining = 3
  }

  /// A new VMO of `size` bytes (rounded up to pages), zeroed.
  public static func create(size: Int) throws(Status) -> Handle { Handle(raw: try Kernel.vmoCreate(size)) }

  public static func size(_ vmo: borrowing Handle) throws(Status) -> Int { try Kernel.vmoSize(vmo.raw) }

  public static func read(_ vmo: borrowing Handle, offset: Int, count: Int) throws(Status) -> [UInt8] {
    try Kernel.vmoRead(vmo.raw, offset, count)
  }

  public static func write(_ vmo: borrowing Handle, offset: Int, _ bytes: [UInt8]) throws(Status) {
    try Kernel.vmoWrite(vmo.raw, offset, bytes)
  }

  /// A VMO over physical memory, `address` and `size` page-aligned, which
  /// an MMIO resource must cover (croi K9a). Its mappings are uncached
  /// device memory unless its cache policy is changed before the first.
  public static func physical(resource: borrowing Handle, address: UInt64, size: Int) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoCreatePhysical(resource.raw, address, size))
  }

  /// Sets how the VMO's mappings are cached; only while it has none.
  public static func setCachePolicy(_ vmo: borrowing Handle, _ policy: CachePolicy) throws(Status) {
    try Kernel.vmoSetCachePolicy(vmo.raw, policy)
  }

  /// Maps `length` bytes from `offset` (a page multiple) into this process.
  public static func map(_ vmo: borrowing Handle, offset: Int = 0, length: Int, writable: Bool = true) throws(Status)
    -> Mapping
  {
    unsafe Mapping(address: try Kernel.vmoMap(vmo.raw, offset, length, writable), length: length)
  }
}

/// A VMO's range mapped into this process; unmapped when dropped. The
/// mapping keeps the VMO alive.
@safe public struct Mapping: ~Copyable {
  public let address: UnsafeMutableRawPointer
  public let length: Int

  init(address: UnsafeMutableRawPointer, length: Int) {
    unsafe self.address = address
    self.length = length
  }

  deinit { unsafe Kernel.vmoUnmap(address, length) }

  public func load<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
    precondition(offset >= 0 && offset + MemoryLayout<T>.size <= length)
    return unsafe address.loadUnaligned(fromByteOffset: offset, as: T.self)
  }

  public func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    precondition(offset >= 0 && offset + MemoryLayout<T>.size <= length)
    unsafe address.storeBytes(of: value, toByteOffset: offset, as: T.self)
  }
}

/// Resources (croi K9a, Zircon's): the right to a range of hardware, MMIO
/// addresses, interrupts or I/O ports. A child lies inside its parent; the
/// launcher grants its ranged roots by manifest (`resource mmio`).
public enum Resource {
  /// A resource for `base` and `size` of `kind`, inside `parent`'s range.
  /// `exclusive`: no other may overlap it (only from a ranged root).
  public static func create(parent: borrowing Handle, kind: ResourceKind, base: UInt64, size: UInt64,
                            name: String, exclusive: Bool = false) throws(Status) -> Handle
  {
    Handle(raw: try Kernel.resourceCreate(parent.raw, kind.rawValue | (exclusive ? 0x1_0000 : 0), base, size, name))
  }

  /// What a resource grants (object_get_info, RESOURCE).
  public static func info(_ resource: borrowing Handle) throws(Status) -> ResourceInfo {
    try Kernel.resourceInfo(resource.raw)
  }
}

public struct ResourceInfo: Equatable, Sendable {
  public var kind: UInt32
  public var flags: UInt32
  public var base: UInt64
  /// 0 for a kind's ranged root.
  public var size: UInt64
  public var name: String

  public init(kind: UInt32, flags: UInt32, base: UInt64, size: UInt64, name: String) {
    self.kind = kind
    self.flags = flags
    self.base = base
    self.size = size
    self.name = name
  }
}

/// I/O ports (amd64): a process may use the ports it has requested with
/// an IOPORT resource that covers them; any other faults.
public enum IOPorts {
  public static func request(_ resource: borrowing Handle, base: UInt16, count: UInt16) throws(Status) {
    try Kernel.ioportsRequest(resource.raw, base, count)
  }

  public static func release(_ resource: borrowing Handle, base: UInt16, count: UInt16) throws(Status) {
    try Kernel.ioportsRelease(resource.raw, base, count)
  }

  /// `in` and `out` of 1, 2 or 4 bytes (`width`).
  public static func read(_ port: UInt16, width: Int) -> UInt32 { Kernel.portIn(port, width) }
  public static func write(_ port: UInt16, width: Int, _ value: UInt32) { Kernel.portOut(port, width, value) }
}

/// The kernel's log (croi's debuglog, Zircon's): a ring of records every
/// process's stdout writes to. Reading needs the debuglog system resource
/// (system base 12); a reader starts at the oldest record still kept.
public enum Debuglog {
  /// The system resource's base that grants reading.
  public static let systemBase: UInt64 = 12

  /// A record: its sequence (one more than the one before; a gap means
  /// records were dropped), severity, monotonic time, writer and text.
  public struct Record: Sendable {
    public var sequence: UInt64
    public var severity: UInt8
    public var timestamp: Int64
    public var pid: UInt64
    public var tid: UInt64
    public var text: [UInt8]
  }

  /// A log this process reads, with a resource that grants it.
  public static func reader(resource: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.debuglogCreate(resource.raw, readable: true))
  }

  /// The next record, or `shouldWait` if there is none; the handle is
  /// READABLE (`Signals.readable`) while one is.
  public static func read(_ log: borrowing Handle) throws(Status) -> Record { try Kernel.debuglogRead(log.raw) }
}

/// Interrupt objects (croi K9c, Zircon's): a device's interrupt, by its
/// number (amd64 and rv64 a GSI, arm64 an INTID) under an IRQ resource
/// covering it, or a virtual one. Taken by a thread in `wait`, or as port
/// packets (`bind`, the port made with `bindToInterrupt`) re-armed by
/// `ack`. A level interrupt is masked from when it fires until then.
public enum Interrupt {
  /// How the line signals (interrupt_create's mode).
  public enum Mode: UInt32, Sendable {
    /// What firmware says (amd64: MADT overrides, else ISA edge-high, PCI level-low).
    case `default` = 0
    case edgeLow = 2
    case edgeHigh = 4
    case levelLow = 6
    case levelHigh = 8
  }

  /// A port packet's type for an interrupt: payload.0 is its timestamp.
  public static let packetType: UInt32 = 7

  public static func create(resource: borrowing Handle, number: UInt32, mode: Mode = .default) throws(Status) -> Handle {
    Handle(raw: try Kernel.interruptCreate(resource.raw, number, mode.rawValue))
  }

  /// One fired by `trigger`, not a device.
  public static func virtual() throws(Status) -> Handle {
    Handle(raw: try Kernel.interruptCreate(0, 0, 0x10))
  }

  /// Packets to `port` with `key`, one an interrupt.
  public static func bind(_ interrupt: borrowing Handle, port: borrowing Handle, key: UInt64) throws(Status) {
    try Kernel.interruptBind(interrupt.raw, port.raw, key)
  }

  public static func ack(_ interrupt: borrowing Handle) throws(Status) { try Kernel.interruptAck(interrupt.raw) }

  /// Waits for the next interrupt; its timestamp (monotonic ns).
  public static func wait(_ interrupt: borrowing Handle) throws(Status) -> Int64 { try Kernel.interruptWait(interrupt.raw) }

  public static func trigger(_ interrupt: borrowing Handle, timestamp: Int64) throws(Status) {
    try Kernel.interruptTrigger(interrupt.raw, timestamp)
  }

  /// Routes it to a CPU of `cpus` (bit n, CPU n): croi's, as policy sets it.
  public static func setAffinity(_ interrupt: borrowing Handle, cpus: UInt64) throws(Status) {
    try Kernel.interruptSetAffinity(interrupt.raw, cpus)
  }
}

/// DMA (croi K9e, Zircon's): an IOMMU, a bus transaction initiator (BTI)
/// per device under it, and memory pinned through the BTI for the device
/// to reach, its pages held until unpinned. croi has only the stub IOMMU
/// so far: device addresses are physical ones.
public enum DMA {
  /// The bti_pin options.
  public struct Pin: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = Pin(rawValue: 1 << 0)
    public static let write = Pin(rawValue: 1 << 1)
    public static let execute = Pin(rawValue: 1 << 2)
    public static let compress = Pin(rawValue: 1 << 3)
    public static let contiguous = Pin(rawValue: 1 << 4)
  }

  /// A BTI's DMA properties (croi's bti_set_properties): addresses below
  /// 2^addressBits, inside [windowBase, windowBase + windowSize) if the
  /// size isn't 0, and the memory's coherency. Only ever narrowed.
  public struct Properties: Equatable, Sendable {
    public var addressBits: UInt32
    public var coherent: Bool
    public var windowBase: UInt64
    public var windowSize: UInt64
    public init(addressBits: UInt32 = 64, coherent: Bool = true, windowBase: UInt64 = 0, windowSize: UInt64 = 0) {
      self.addressBits = addressBits
      self.coherent = coherent
      self.windowBase = windowBase
      self.windowSize = windowSize
    }
  }

  /// The system resource's base that grants making an IOMMU.
  public static let iommuSystemBase: UInt64 = 8

  /// The stub IOMMU: no translation. Its BTIs are a trust decision that
  /// croi logs.
  public static func stubIOMMU(resource: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.iommuCreateStub(resource.raw))
  }

  /// A BTI for the device with `id` (a PCI device's bus, device and
  /// function, by convention).
  public static func bti(iommu: borrowing Handle, id: UInt64) throws(Status) -> Handle {
    Handle(raw: try Kernel.btiCreate(iommu.raw, id))
  }

  public static func setProperties(_ bti: borrowing Handle, _ p: Properties) throws(Status) {
    try Kernel.btiSetProperties(bti.raw, p)
  }

  /// A VMO of `size` bytes contiguous in device address space, inside the
  /// BTI's properties.
  public static func contiguousVMO(bti: borrowing Handle, size: Int, alignmentLog2: UInt32 = 0) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoCreateContiguous(bti.raw, size, alignmentLog2))
  }

  /// Pins `size` bytes of the VMO from `offset` (page aligned); the PMT
  /// that holds them, and their device addresses (`count` of them: one
  /// with `.contiguous`, else one a page). Unpin with `unpin`: a PMT
  /// closed while pinned is quarantined.
  public static func pin(_ bti: borrowing Handle, _ vmo: borrowing Handle, offset: Int, size: Int, options: Pin,
                         count: Int) throws(Status) -> (pmt: UInt32, addresses: [UInt64])
  {
    try Kernel.btiPin(bti.raw, vmo.raw, offset, size, options.rawValue, count)
  }

  /// Unpins; the PMT is consumed.
  public static func unpin(pmt: UInt32) throws(Status) { try Kernel.pmtUnpin(pmt) }

  public static func releaseQuarantine(_ bti: borrowing Handle) throws(Status) {
    try Kernel.btiReleaseQuarantine(bti.raw)
  }
}

/// Timers: SIGNALED at a deadline.
public enum Timer {
  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.timerCreate()) }
  public static func set(_ timer: borrowing Handle, deadline: Int64) throws(Status) {
    try Kernel.timerSet(timer.raw, deadline)
  }
  public static func cancel(_ timer: borrowing Handle) throws(Status) { try Kernel.timerCancel(timer.raw) }
}

/// Jobs: the tree processes live in; killing one kills all under it.
public enum Job {
  public static func create(parent: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.jobCreate(parent.raw))
  }
}

public struct ProcessInfo: Equatable, Sendable {
  public var returnCode: Int64
  public var started: Bool
  public var exited: Bool
  public init(returnCode: Int64, started: Bool, exited: Bool) {
    self.returnCode = returnCode
    self.started = started
    self.exited = exited
  }
}

/// Processes: a handle table and threads. Natively an address space too.
public enum Process {
  public static func create(job: borrowing Handle, name: String) throws(Status) -> Handle {
    Handle(raw: try Kernel.processCreate(job.raw, name))
  }

  /// Starts the process: its first thread runs `entry` with `arg` (moved
  /// into the process). The thread's handle. Hosted, `entry` is a Swift
  /// function given `arg`; natively, an ELF image the process is loaded
  /// from, which finds `arg` as its PA_USER0 startup handle (M3d).
  ///
  /// `extra` are more handles moved into the process, each with its
  /// processargs info word: natively it finds them with
  /// `StartupHandles.take` (the trace region, M3f); hosted processes take
  /// their startup from `arg` alone, so they are closed.
  public static func start(_ process: borrowing Handle, entry: ProgramEntry, arg: consuming Handle,
                           extra: [(info: UInt32, handle: UInt32)] = []) throws(Status) -> Handle
  {
    let thread: Handle
    do throws(Status) {
      thread = Handle(raw: try Kernel.threadCreate(process.raw))
    } catch {
      for e in extra { Kernel.close(e.handle) }
      throw error
    }
    try Kernel.processStart(process.raw, thread.raw, arg.release(), entry, extra)
    return thread
  }

  /// The calling process ends with `code`.
  public static func exit(code: Int64) -> Never { Kernel.exit(code) }

  /// A handle to the calling process.
  public static func current() throws(Status) -> Handle { Handle(raw: try Kernel.processSelf()) }

  public static func info(_ process: borrowing Handle) throws(Status) -> ProcessInfo { try Kernel.processInfo(process.raw) }
}

/// Threads: more threads in a process (a process's first comes with
/// Process.start).
public enum Thread {
  public static func create(process: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.threadCreate(process.raw))
  }

  /// Starts `thread` running `body`; the thread exits when it returns.
  /// Natively the thread gets a stack of its own (lib/sys/backend/native).
  public static func start(_ thread: borrowing Handle, _ body: @escaping @Sendable () -> Void) throws(Status) {
    try Kernel.threadStart(thread.raw, body)
  }

  /// A new thread in the calling process, running `body`. Its handle:
  /// `join` it, or drop it to let the thread run on alone.
  public static func spawn(_ body: @escaping @Sendable () -> Void) throws(Status) -> Handle {
    let process = try Process.current()
    let thread = try create(process: process)
    try start(thread, body)
    return thread
  }

  /// Waits until `thread` has ended.
  public static func join(_ thread: borrowing Handle) throws(Status) {
    _ = try thread.wait(for: Signals.terminated)
  }
}

/// task_kill: a job (with all under it), a process or a thread.
public func kill(_ task: borrowing Handle) throws(Status) { try Kernel.kill(task.raw) }
