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
  /// A new VMO of `size` bytes (rounded up to pages), zeroed.
  public static func create(size: Int) throws(Status) -> Handle { Handle(raw: try Kernel.vmoCreate(size)) }

  public static func size(_ vmo: borrowing Handle) throws(Status) -> Int { try Kernel.vmoSize(vmo.raw) }

  public static func read(_ vmo: borrowing Handle, offset: Int, count: Int) throws(Status) -> [UInt8] {
    try Kernel.vmoRead(vmo.raw, offset, count)
  }

  public static func write(_ vmo: borrowing Handle, offset: Int, _ bytes: [UInt8]) throws(Status) {
    try Kernel.vmoWrite(vmo.raw, offset, bytes)
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
  /// function; natively, a program image's entry point (M3).
  public static func start(_ process: borrowing Handle, entry: ProgramEntry, arg: consuming Handle) throws(Status)
    -> Handle
  {
    let thread = Handle(raw: try Kernel.threadCreate(process.raw))
    try Kernel.processStart(thread.raw, arg.release(), entry)
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
