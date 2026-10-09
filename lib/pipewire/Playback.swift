// SPDX-License-Identifier: BSD-3-Clause

// A playback node on PipeWire, spoken directly
// (docs/research/pipewire-protocol.md, "Path A"): a client-node with one
// mono F32P output port per channel, linked by us to the default sink's
// ports, driven by the graph through its activation record. One thread
// handles both the socket and the node's eventfd, so control messages are
// applied between cycles and never race the real-time path.

import Glibc
import TDLinux

public struct PlaybackOptions: Sendable {
  public var name: String
  public var channels: Int
  public var rate: Int
  public var quantum: Int
  public init(name: String = "todhchai", channels: Int = 2, rate: Int = 48_000, quantum: Int = 128) {
    self.name = name
    self.channels = channels
    self.rate = rate
    self.quantum = quantum
  }
}

// Protocol constants (§3, §4).
enum Op {
  // Core methods and events.
  static let hello: UInt8 = 1, sync: UInt8 = 2, pong: UInt8 = 3, getRegistry: UInt8 = 5, createObject: UInt8 = 6
  static let coreDone: UInt8 = 1, corePing: UInt8 = 2, coreError: UInt8 = 3, coreBoundProps: UInt8 = 8
  static let coreAddMem: UInt8 = 6, coreRemoveMem: UInt8 = 7
  // Client, registry, metadata.
  static let updateProperties: UInt8 = 2, bind: UInt8 = 1
  static let global: UInt8 = 0, globalRemove: UInt8 = 1, metadataProperty: UInt8 = 0
  // ClientNode methods and events.
  static let nodeUpdate: UInt8 = 2, portUpdate: UInt8 = 3, setActive: UInt8 = 4
  static let transport: UInt8 = 0, setIO: UInt8 = 2, command: UInt8 = 4, portSetParam: UInt8 = 7
  static let portUseBuffers: UInt8 = 8, portSetIO: UInt8 = 9, setActivation: UInt8 = 10
}

// The activation record (§5.3, PipeWire 1.6.9, activation version 1).
enum Activation {
  static let status = 0, pending = 16, signalTime = 32, awakeTime = 40, finishTime = 48
  static let clientVersion = 540, serverVersion = 544, activeDriverID = 548
  static let notTriggered: UInt32 = 0, triggered: UInt32 = 1, awake: UInt32 = 2, finished: UInt32 = 3
  static let inactive: UInt32 = 4
}

public final class PipeWirePlayback {
  let c: PipeWireConnection
  let options: PlaybackOptions
  // Object ids are ours to choose, and must be dense: each new one is the
  // next unused (the server refuses a gap with ENOSPC).
  let registryID: UInt32 = 2
  var nodeID: UInt32 = UInt32.max
  var nextID: UInt32 = 3
  var syncSeq: Int32 = 1
  var lastDone: Int32 = 0
  var metadataID: UInt32?

  struct Global { var type: String; var props: [String: String] }
  var globals: [UInt32: Global] = [:]
  var defaultSinkName: String?
  var errors: [PipeWireError] = []

  // Memory the server shared with us, and what we mapped of it.
  var mems: [UInt32: Int32] = [:]  // mem id → fd
  var mappings: [(UnsafeMutableRawPointer, Int)] = []

  // The node.
  var nodeGlobal: UInt32?
  var activation: UnsafeMutableRawPointer?
  public private(set) var readFD: Int32 = -1
  var position: UnsafeMutableRawPointer?  // the driver's spa_io_position
  struct Target { var record: UnsafeMutableRawPointer; var fd: Int32 }
  var targets: [UInt32: Target] = [:]
  var started = false

  // Ports: one per channel.
  struct Buffer { var data: UnsafeMutableRawPointer; var maxSize: Int; var chunk: UnsafeMutableRawPointer }
  struct Port {
    var channel: String
    var buffers: [Buffer] = []
    var io: [UInt32: UnsafeMutableRawPointer] = [:]  // mix id → spa_io_buffers
    var next = 0
    var formatSet = false
  }
  var ports: [Port]
  let scratch: UnsafeMutableBufferPointer<Float>
  public private(set) var underruns = 0
  public private(set) var cycles = 0

  static let maxFrames = 8192

  /// Connects, creates the node and links it to the default sink. Blocks
  /// until the graph starts it, or throws.
  public init(_ options: PlaybackOptions, timeout: Duration = .seconds(5)) throws(PipeWireError) {
    self.options = options
    c = try PipeWireConnection()
    let names = options.channels == 1 ? ["MONO"] : ["FL", "FR"] + (2..<max(2, options.channels)).map { "AUX\($0 - 2)" }
    ports = names.prefix(options.channels).map { Port(channel: $0) }
    scratch = .allocate(capacity: Self.maxFrames * options.channels)
    let deadline = monotonicNS() + timeout.nanoseconds

    try c.send(0, Op.hello, [.int(4)])
    try c.send(1, Op.updateProperties, [.struct(dictionaryPods([
      ("application.name", options.name), ("application.process.id", "\(getpid())"),
    ]))])
    try c.send(0, Op.getRegistry, [.int(3), .int(Int32(registryID))])
    try settle(deadline)

    // The default sink, from the session manager's metadata if there is one.
    if let metadata = globals.first(where: {
      $0.value.type == "PipeWire:Interface:Metadata" && $0.value.props["metadata.name"] == "default"
    }) {
      let id = nextID
      nextID += 1
      metadataID = id
      try c.send(registryID, Op.bind, [
        .int(Int32(metadata.key)), .string("PipeWire:Interface:Metadata"), .int(3), .int(Int32(id)),
      ])
      try settle(deadline)
    }
    guard let sink = chooseSink() else { throw .protocolError("no audio sink to play to") }

    // The node and its ports (§4.1, §4.2, §4.4).
    nodeID = nextID
    nextID += 1
    try c.send(0, Op.createObject, [
      .string("client-node"), .string("PipeWire:Interface:ClientNode"), .int(6),
      .struct(dictionaryPods([
        ("node.name", options.name), ("node.description", options.name), ("media.type", "Audio"),
        ("media.category", "Playback"), ("media.role", "Game"), ("node.autoconnect", "false"),
        ("node.latency", "\(options.quantum)/\(options.rate)"), ("node.rate", "1/\(options.rate)"),
      ])),
      .int(Int32(nodeID)),
    ])
    try c.send(nodeID, Op.nodeUpdate, [
      .int(3), .int(0),
      .struct([.int(0), .int(Int32(ports.count)), .long(7), .long(0)]
        + dictionaryPods([("node.name", options.name)]) + [.int(0)]),
    ])
    for i in ports.indices { try sendPortUpdate(i) }

    // Registration and transport, then our ports appear as globals.
    try pump(deadline) { $0.activation != nil && $0.nodeGlobal != nil }
    try c.send(nodeID, Op.setActive, [.bool(true)])
    try pump(deadline) { $0.ourPortGlobals().count == $0.ports.count }

    // Link each of our ports to the sink's port for the same channel.
    let ours = ourPortGlobals()
    for port in ports {
      guard let out = ours[port.channel], let input = sinkPort(sink, channel: port.channel) ?? sinkPort(sink, channel: nil)
      else { continue }
      let id = nextID
      nextID += 1
      try c.send(0, Op.createObject, [
        .string("link-factory"), .string("PipeWire:Interface:Link"), .int(3),
        .struct(dictionaryPods([
          ("link.output.node", "\(nodeGlobal!)"), ("link.output.port", "\(out)"),
          ("link.input.node", "\(sink)"), ("link.input.port", "\(input)"),
        ])),
        .int(Int32(id)),
      ])
    }
    try pump(deadline) {
      $0.started && $0.position != nil && $0.ports.allSatisfy { !$0.io.isEmpty && !$0.buffers.isEmpty }
    }
  }

  deinit {
    if let a = activation { td_atomic_store_u32(a + Activation.status, Activation.inactive) }
    for (p, n) in mappings { munmap(p, n) }
    for fd in mems.values { close(fd) }
    for t in targets.values { close(t.fd) }
    if readFD >= 0 { close(readFD) }
    scratch.deallocate()
  }

  /// The frames the driver asks for each cycle.
  public var quantum: Int {
    guard let p = position else { return options.quantum }
    return Int(p.load(fromByteOffset: 96, as: UInt64.self))
  }

  /// The socket, to poll with `readFD`.
  public var socketFD: Int32 { c.fd }

  // MARK: Control messages

  /// Sends Sync and handles messages until its Done.
  func settle(_ deadline: UInt64) throws(PipeWireError) {
    syncSeq += 1
    let seq = syncSeq
    try c.send(0, Op.sync, [.int(0), .int(seq)])
    try pump(deadline) { $0.lastDone >= seq }
  }

  /// Handles messages until `done` holds or `deadline` passes.
  func pump(_ deadline: UInt64, _ done: (PipeWirePlayback) -> Bool) throws(PipeWireError) {
    while true {
      if let e = errors.first { throw e }
      if done(self) { return }
      let now = monotonicNS()
      guard now < deadline else { throw .protocolError("PipeWire didn't finish setting up the stream in time") }
      var pfd = pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, Int32(min(100, (deadline - now) / 1_000_000 + 1))) > 0 { try handleSocket() }
    }
  }

  /// Reads and applies everything on the socket. Called between cycles.
  public func handleSocket() throws(PipeWireError) {
    for m in try c.receive() { try handle(m) }
  }

  func handle(_ m: PipeWireMessage) throws(PipeWireError) {
    let f = m.fields
    func u(_ i: Int) -> UInt32 {
      guard i < f.count else { return 0 }
      switch f[i] {
      case .int(let v): return UInt32(bitPattern: v)
      case .id(let v): return v
      case .long(let v): return UInt32(truncatingIfNeeded: v)
      default: return 0
      }
    }
    var kept: Set<Int32> = []
    switch (m.id, m.opcode) {
    case (0, Op.corePing):
      try c.send(0, Op.pong, Array(f.prefix(2)))
    case (0, Op.coreDone):
      if f.count > 1, let seq = f[1].int { lastDone = max(lastDone, seq) }
    case (0, Op.coreError):
      let message = f.count > 3 ? f[3].string ?? "" : ""
      errors.append(.server(id: u(0), res: Int32(bitPattern: u(2)), message: message))
    case (0, Op.coreBoundProps):
      if u(0) == nodeID { nodeGlobal = u(1) }
    case (0, Op.coreAddMem):
      let fd = m.fd(2)
      mems[u(0)] = fd
      kept.insert(fd)
    case (0, Op.coreRemoveMem):
      if let fd = mems.removeValue(forKey: u(0)) { close(fd) }
    case (registryID, Op.global):
      guard f.count >= 5, let type = f[2].string else { break }
      let (props, _) = readDictionary(f[4].fields ?? [], at: 0)
      globals[u(0)] = Global(type: type, props: props)
    case (registryID, Op.globalRemove):
      globals[u(0)] = nil
    case (let id, Op.metadataProperty) where id == metadataID:
      // default.audio.sink = {"name":"..."}
      if f.count >= 4, f[1].string == "default.audio.sink", let json = f[3].string { defaultSinkName = jsonName(json) }
    case (nodeID, Op.transport):
      readFD = m.fd(0)
      kept.insert(readFD)
      guard let a = map(u(2), offset: u(3), size: u(4)) else { throw .protocolError("can't map the activation record") }
      let server = a.load(fromByteOffset: Activation.serverVersion, as: UInt32.self)
      guard server == 1 else { throw .protocolError("activation version \(server); this client speaks 1 (PipeWire 1.2 to 1.6)") }
      a.storeBytes(of: 1, toByteOffset: Activation.clientVersion, as: UInt32.self)
      activation = a
    case (nodeID, Op.setIO):
      if u(0) == 7 {  // Position: the driver's, and whose cycles we follow
        position = u(1) == UInt32.max ? nil : map(u(1), offset: u(2), size: u(3))
        if let p = position, let a = activation {
          a.storeBytes(of: p.load(fromByteOffset: 4, as: UInt32.self), toByteOffset: Activation.activeDriverID, as: UInt32.self)
        }
      }
    case (nodeID, Op.setActivation):
      let node = u(0)
      if let old = targets.removeValue(forKey: node) { close(old.fd) }
      let fd = m.fd(1)
      if u(2) != UInt32.max, fd >= 0, let record = map(u(2), offset: u(3), size: u(4)) {
        targets[node] = Target(record: record, fd: fd)
        kept.insert(fd)
      }
    case (nodeID, Op.command):
      if case .object(_, let command, _)? = f.first { applyCommand(command) }
    case (nodeID, Op.portSetParam):
      let port = Int(u(1))
      if u(2) == 4, port < ports.count, f.count > 4 {  // Format
        if case .none = f[4] {
          ports[port].formatSet = false
          ports[port].buffers = []
        } else {
          ports[port].formatSet = true
        }
        try sendPortUpdate(port)
      }
    case (nodeID, Op.portUseBuffers):
      try useBuffers(f)
    case (nodeID, Op.portSetIO):
      let port = Int(u(1)), mix = u(2)
      guard port < ports.count, u(3) == 1 else { break }  // Buffers IO
      if u(4) == UInt32.max {
        ports[port].io[mix] = nil
      } else if let io = map(u(4), offset: u(5), size: u(6)) {
        ports[port].io[mix] = io
      }
    default:
      break
    }
    for fd in m.fds where fd >= 0 && !kept.contains(fd) { close(fd) }
  }

  func applyCommand(_ command: UInt32) {
    guard let a = activation else { return }
    switch command {
    case 2:  // Start
      td_atomic_store_u32(a + Activation.status, Activation.finished)
      started = true
    case 0, 1:  // Suspend, Pause
      let old = td_atomic_xchg_u32(a + Activation.status, Activation.inactive)
      if old == Activation.notTriggered || old == Activation.triggered || old == Activation.awake { triggerTargets() }
      started = false
    default:
      break
    }
  }

  func sendPortUpdate(_ i: Int) throws(PipeWireError) {
    func format(_ id: UInt32) -> Pod {
      .object(type: 0x40003, id: id, [Pod.Property(1, .id(1)), Pod.Property(2, .id(2)), Pod.Property(0x10001, .id(0x206))])
    }
    let buffers: Pod = .object(type: 0x40004, id: 5, [
      Pod.Property(1, .choice(type: 1, [.int(2), .int(1), .int(8)])), Pod.Property(2, .int(1)),
      Pod.Property(3, .int(Int32(Self.maxFrames * 4))), Pod.Property(4, .int(4)),
    ])
    let io: Pod = .object(type: 0x40006, id: 7, [Pod.Property(1, .id(1)), Pod.Property(2, .int(8))])
    var params: [Pod] = [format(3), io]
    var info: [(UInt32, Int32)] = [(3, 2), (7, 2), (4, 4)]  // EnumFormat READ, IO READ, Format WRITE
    if ports[i].formatSet {
      params += [format(4), buffers]
      info = [(3, 2), (7, 2), (4, 6), (5, 2)]  // Format READWRITE, Buffers READ
    }
    let props = dictionaryPods([
      ("port.name", "output_\(ports[i].channel)"), ("audio.channel", ports[i].channel),
      ("format.dsp", "32 bit float mono audio"),
    ])
    let paramInfo: [Pod] = [.int(Int32(info.count))] + info.flatMap { [Pod.id($0.0), .int($0.1)] }
    try c.send(nodeID, Op.portUpdate,
               [.int(1), .int(Int32(i)), .int(3), .int(Int32(params.count))] + params
                 + [.struct([.long(15), .long(0), .int(0), .int(1)] + props + paramInfo)])
  }

  func useBuffers(_ f: [Pod]) throws(PipeWireError) {
    func n(_ i: Int) -> Int64 {
      guard i < f.count else { return 0 }
      switch f[i] {
      case .int(let v): return Int64(v)
      case .id(let v): return Int64(v)
      case .long(let v): return v
      default: return 0
      }
    }
    let port = Int(n(1))
    guard port < ports.count else { return }
    var buffers: [Buffer] = []
    var i = 5
    for _ in 0..<Int(n(4)) {
      let mem = UInt32(truncatingIfNeeded: n(i)), offset = UInt32(truncatingIfNeeded: n(i + 1))
      let size = UInt32(truncatingIfNeeded: n(i + 2))
      let metas = Int(n(i + 3))
      i += 4
      var metaBytes = 0
      for _ in 0..<metas {
        metaBytes += (Int(n(i + 1)) + 7) & ~7
        i += 2
      }
      let datas = Int(n(i))
      i += 1
      guard let region = map(mem, offset: offset, size: size) else { throw .protocolError("can't map buffers") }
      for d in 0..<datas {
        let type = n(i), data = n(i + 1), mapOffset = n(i + 3), maxSize = Int(n(i + 4))
        i += 5
        let chunk = region + metaBytes + 16 * d
        let memory: UnsafeMutableRawPointer?
        switch type {
        case 1: memory = region + Int(data)  // MemPtr: an offset in the region
        case 4:  // MemId: another block
          memory = map(UInt32(truncatingIfNeeded: data), offset: UInt32(truncatingIfNeeded: mapOffset), size: UInt32(maxSize))
        default: memory = nil
        }
        if d == 0, let memory { buffers.append(Buffer(data: memory, maxSize: maxSize, chunk: chunk)) }
      }
    }
    ports[port].buffers = buffers
    ports[port].next = 0
  }

  /// Maps (offset, size) of a memory block, page-aligned (§5.1).
  func map(_ mem: UInt32, offset: UInt32, size: UInt32) -> UnsafeMutableRawPointer? {
    guard let fd = mems[mem] else { return nil }
    let page = Int(sysconf(Int32(_SC_PAGESIZE)))
    let start = Int(offset) & ~(page - 1), inPage = Int(offset) - start
    let length = (inPage + Int(size) + page - 1) & ~(page - 1)
    let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off_t(start))
    guard let p, p != MAP_FAILED else { return nil }
    mappings.append((p, length))
    return p + inPage
  }

  // MARK: Choosing where to play

  func chooseSink() -> UInt32? {
    let sinks = globals.filter { $0.value.type == "PipeWire:Interface:Node" && $0.value.props["media.class"] == "Audio/Sink" }
    if let name = defaultSinkName, let s = sinks.first(where: { $0.value.props["node.name"] == name }) { return s.key }
    return sinks.keys.sorted().first
  }

  func sinkPort(_ sink: UInt32, channel: String?) -> UInt32? {
    globals.first {
      $0.value.type == "PipeWire:Interface:Port" && $0.value.props["node.id"] == "\(sink)"
        && $0.value.props["port.direction"] == "in" && (channel == nil || $0.value.props["audio.channel"] == channel)
    }?.key
  }

  /// Our ports' global ids, by channel.
  func ourPortGlobals() -> [String: UInt32] {
    guard let node = nodeGlobal else { return [:] }
    var out: [String: UInt32] = [:]
    for (id, g) in globals where g.type == "PipeWire:Interface:Port" && g.props["node.id"] == "\(node)" {
      if let ch = g.props["audio.channel"] { out[ch] = id }
    }
    return out
  }

  /// The "name" in a JSON object like {"name":"alsa_output.x"}.
  func jsonName(_ json: String) -> String? {
    guard let key = json.firstRange(of: "\"name\"") else { return nil }
    let rest = json[key.upperBound...].drop { $0 == " " || $0 == ":" }.drop { $0 == " " || $0 == "\"" }
    return String(rest.prefix { $0 != "\"" })
  }

  // MARK: The cycle (§5.4, §5.5)

  /// Runs one graph cycle if the node was triggered: renders the quantum
  /// interleaved, splits it into the per-channel buffers, and triggers the
  /// targets. Call when `readFD` is readable.
  public func cycle(_ render: (UnsafeMutableBufferPointer<Float>) -> Void) {
    var count: UInt64 = 0
    _ = read(readFD, &count, 8)
    if count > 1 { underruns += Int(count - 1) }
    guard started, let a = activation else { return }
    guard td_atomic_cas_u32(a + Activation.status, Activation.triggered, Activation.awake) != 0 else { return }
    a.storeBytes(of: monotonicNS(), toByteOffset: Activation.awakeTime, as: UInt64.self)

    let frames = min(Self.maxFrames, quantum)
    let channels = ports.count
    let out = UnsafeMutableBufferPointer(rebasing: scratch[0..<(frames * channels)])
    out.update(repeating: 0)
    render(out)
    for p in ports.indices where !ports[p].buffers.isEmpty {
      // Reuse a buffer the consumer hasn't taken; otherwise the next one.
      var id = ports[p].next
      if let io = ports[p].io.values.first, io.load(as: Int32.self) == 2 {
        id = Int(io.load(fromByteOffset: 4, as: UInt32.self)) % ports[p].buffers.count
      } else {
        ports[p].next = (id + 1) % ports[p].buffers.count
      }
      let b = ports[p].buffers[id]
      let n = min(frames, b.maxSize / 4)
      let samples = b.data.assumingMemoryBound(to: Float.self)
      for f in 0..<n { samples[f] = out[f * channels + p] }
      b.chunk.storeBytes(of: 0, as: UInt32.self)
      b.chunk.storeBytes(of: UInt32(n * 4), toByteOffset: 4, as: UInt32.self)
      b.chunk.storeBytes(of: 4, toByteOffset: 8, as: Int32.self)
      b.chunk.storeBytes(of: 0, toByteOffset: 12, as: Int32.self)
      for io in ports[p].io.values {
        io.storeBytes(of: UInt32(id), toByteOffset: 4, as: UInt32.self)
        td_atomic_store_i32(io, 2)  // HAVE_DATA
      }
    }
    cycles += 1
    let old = td_atomic_xchg_u32(a + Activation.status, Activation.finished)
    a.storeBytes(of: monotonicNS(), toByteOffset: Activation.finishTime, as: UInt64.self)
    if old == Activation.awake { triggerTargets() }
  }

  func triggerTargets() {
    for t in targets.values {
      guard td_atomic_sub_fetch_i32(t.record + Activation.pending, 1) == 0 else { continue }
      let server = t.record.load(fromByteOffset: Activation.serverVersion, as: UInt32.self)
      if server >= 1 {
        guard td_atomic_cas_u32(t.record + Activation.status, Activation.notTriggered, Activation.triggered) != 0 else {
          continue
        }
      } else {
        td_atomic_store_u32(t.record + Activation.status, Activation.triggered)
      }
      t.record.storeBytes(of: monotonicNS(), toByteOffset: Activation.signalTime, as: UInt64.self)
      var one: UInt64 = 1
      _ = write(t.fd, &one, 8)
    }
  }
}

func monotonicNS() -> UInt64 {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

extension Duration {
  var nanoseconds: UInt64 {
    let (s, a) = components
    return s < 0 ? 0 : UInt64(s) * 1_000_000_000 + UInt64(a / 1_000_000_000)
  }
}
