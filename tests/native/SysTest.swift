// SPDX-License-Identifier: BSD-3-Clause

// bin/sys-test: Sys over croi's syscalls (M3b), run by userboot under
// `td boot --test --next bin/sys-test`. Each check names what failed and
// exits 1; all passing prints "sys-test: ok" and exits 0. The hosted
// suite (tests/sys) checks the same calls over the hosted kernel.

import LibSys
import Sys

@main struct SysTest {
  static func main() {
    do throws(Status) {
      try run()
    } catch {
      print("sys-test: FAILED with status \(error.rawValue)")
      exit(1)
    }
    print("sys-test: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok {
      print("sys-test: FAILED: \(what)")
      exit(1)
    }
  }

  static func status<R>(_ body: () throws(Status) -> R) -> Status {
    do throws(Status) {
      _ = try body()
      return .ok
    } catch {
      return error
    }
  }

  static let ms: Int64 = 1_000_000

  /// The MMIO and IOPORT ranged roots: a resource of each made under them,
  /// q35's host bridge read through a physical VMO over its ECAM page and
  /// through ports 0xCF8/0xCFC, which must agree.
  static func resources() throws(Status) {
    guard let mmioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.mmio))) else {
      check(false, "userboot's MMIO resource")
      return
    }
    let mmio = Handle(raw: mmioRaw)
    let root = try Resource.info(mmio)
    check(root.kind == ResourceKind.mmio.rawValue && root.size == 0, "MMIO ranged root")
    #if arch(x86_64)
      let ecam = try Resource.create(parent: mmio, kind: .mmio, base: 0xE000_0000, size: 4096, name: "sys-test ecam")
      let info = try Resource.info(ecam)
      check(info.base == 0xE000_0000 && info.size == 4096 && info.name == "sys-test ecam", "resource info")
      let vmo = try VMO.physical(resource: ecam, address: 0xE000_0000, size: 4096)
      check(status { () throws(Status) in try VMO.read(vmo, offset: 0, count: 4) } == .notSupported,
            "a device VMO refuses vmo_read")
      let config = try VMO.map(vmo, length: 4096, writable: false)
      let id = config.load(UInt32.self, at: 0)
      check(id & 0xFFFF == 0x8086, "the host bridge's vendor through ECAM")
      check(status { () throws(Status) in
        try VMO.physical(resource: ecam, address: 0xE000_1000, size: 4096)
      } == .outOfRange, "a VMO beyond the resource")

      guard let portsRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.ioport))) else {
        check(false, "userboot's IOPORT resource")
        return
      }
      let ports = Handle(raw: portsRaw)
      let pci = try Resource.create(parent: ports, kind: .ioport, base: 0xCF8, size: 8, name: "sys-test pci")
      try IOPorts.request(pci, base: 0xCF8, count: 8)
      IOPorts.write(0xCF8, width: 4, 0x8000_0000)
      check(IOPorts.read(0xCFC, width: 4) == id, "the host bridge's id through ports 0xCF8/0xCFC")
      try IOPorts.release(pci, base: 0xCF8, count: 8)
      print("sys-test: host bridge \(hex(id & 0xFFFF)):\(hex(id >> 16)) through ECAM and ports")
    #endif
  }

  static func hex(_ v: UInt32) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for shift in stride(from: 12, through: 0, by: -4) { out.append(digits[Int((v >> UInt32(shift)) & 0xF)]) }
    return String(decoding: out, as: UTF8.self)
  }

  static func run() throws(Status) {
    // libsys: argv[0] is the program's bootfs name; the heap's size
    // classes and its large blocks; String comparison (Unicode tables).
    check(Arguments.strings.first == "bin/sys-test", "argv[0]")
    var small: [[UInt8]] = []
    for i in 0..<1000 { small.append([UInt8](repeating: UInt8(truncatingIfNeeded: i), count: i % 300)) }
    let large = [UInt64](repeating: 7, count: 100_000)
    var sum: UInt64 = 0
    for block in small { for b in block { sum &+= UInt64(b) } }
    for v in large { sum &+= v }
    small.removeAll()
    // Σ (i mod 256)(i mod 300) for i < 1000, plus 7 × 100 000.
    check(sum == 17_695_004, "heap checksum")
    check("dia duit" == String(decoding: Array("dia duit".utf8), as: UTF8.self), "String comparison")

    // The clock moves, and sleeping takes time.
    let t0 = Clock.monotonic()
    sleep(until: t0 + 2 * ms)
    check(Clock.monotonic() >= t0 + 2 * ms, "clock and sleep")

    // Handles: rights narrow on duplicate and replace; stale handles fail.
    let event = try Event.create()
    let info = try event.info()
    check(info.type == ObjectType.event && info.rights.contains(.signal), "event info")
    let waitOnly = try event.duplicate([.wait, .inspect])
    check(try waitOnly.info().koid == info.koid, "duplicate's koid")
    check(status { () throws(Status) in try waitOnly.signal(set: Signals.signaled) } == .accessDenied, "narrowed rights")
    let replaced = try waitOnly.replace([.inspect])
    check(try replaced.info().rights == [.inspect], "replace")
    check(status { () throws(Status) in try Handle(raw: 0x7FFF_FFF1).info() } == .badHandle, "bad handle")

    // Signals and waits, with deadlines.
    check(status { () throws(Status) in try event.wait(for: Signals.signaled, deadline: 0) } == .timedOut, "wait times out")
    try event.signal(set: Signals.signaled)
    check(try event.wait(for: Signals.signaled) & Signals.signaled != 0, "event signaled")

    // M2's exit, in Sys: a VMO across a channel, a port wait on a deadline timer.
    let ends = try Channel.create()
    let a = ends.a, b = ends.b
    check(try a.info().relatedKoid == b.info().koid, "channel peers")
    let vmo = try VMO.create(size: 8192)
    try VMO.write(vmo, offset: 4096, Array("dia duit".utf8))
    try Channel.write(a, bytes: [1, 2, 3], handles: [vmo.release()])
    let message = try Channel.read(b)
    check(message.bytes == [1, 2, 3] && message.handles.count == 1, "channel message")
    let received = Handle(raw: message.handles[0])
    check(try VMO.read(received, offset: 4096, count: 8) == Array("dia duit".utf8), "VMO across the channel")
    check(status { () throws(Status) in try Channel.read(b) } == .shouldWait, "empty channel")

    let port = try Port.create()
    let timer = try Timer.create()
    try Timer.set(timer, deadline: Clock.monotonic() + 5 * ms)
    try timer.waitAsync(port: port, key: 7, signals: Signals.signaled)
    let packet = try Port.wait(port, deadline: Clock.monotonic() + 1000 * ms)
    check(packet.key == 7 && packet.trigger & Signals.signaled != 0, "timer packet")
    check(status { () throws(Status) in try Port.wait(port, deadline: Clock.monotonic() + ms) } == .timedOut, "port times out")
    try Port.queue(port, Packet(key: 9, payload: (1, 2, 3, 4)))
    check(try Port.wait(port).payload.3 == 4, "user packet")

    // Mappings see the VMO, and unmap when dropped.
    do {
      let mapping = try VMO.map(received, length: 8192)
      check(mapping.load(UInt8.self, at: 4096) == UInt8(ascii: "d"), "mapping reads")
      mapping.store(UInt64(0x5444_4843_4841_4921), at: 0)
      check(try VMO.read(received, offset: 0, count: 8) == [0x21, 0x49, 0x41, 0x48, 0x43, 0x48, 0x44, 0x54], "mapping writes")
    }

    // Sizes and lengths that aren't pages are rounded up, as Sys promises.
    do {
      let odd = try VMO.create(size: 3584)
      check(try VMO.size(odd) == 4096, "VMO size rounds up to a page")
      let mapping = try VMO.map(odd, length: 3584)
      mapping.store(UInt32(7), at: 3580)
      check(try VMO.read(odd, offset: 3580, count: 4) == [7, 0, 0, 0], "odd-length mapping")
    }

    // Eventpairs see their peer close.
    let pair = try EventPair.create()
    let left = pair.a
    do {
      let right = pair.b
      _ = consume right
    }
    check(try left.wait(for: Signals.peerClosed) & Signals.peerClosed != 0, "peer closed")

    // Threads: a server answering calls on another thread.
    let calls = try Channel.create()
    let client = calls.a
    let serverRaw = calls.b.release()
    let server = try Thread.spawn {
      let channel = Handle(raw: serverRaw)
      while true {
        guard (try? channel.wait(for: Signals.readable | Signals.peerClosed)) != nil,
          let m = try? Channel.read(channel)
        else { return }
        // Echo the call with its txid (the first four bytes) and one more byte.
        try? Channel.write(channel, bytes: m.bytes + [0xEE])
      }
    }
    // Our side of a call, without a wakeup: the clock, and a write and
    // read on one thread.
    do {
      let c0 = Clock.monotonic()
      for _ in 0..<1000 { _ = Clock.monotonic() }
      let clock = (Clock.monotonic() - c0) / 1000
      let local = try Channel.create()
      let w0 = Clock.monotonic()
      for _ in 0..<1000 {
        try Channel.write(local.a, bytes: [1, 2, 3, 4, 5])
        _ = try Channel.read(local.b)
      }
      print("sys-test: clock \(clock) ns; channel write and read on one thread \((Clock.monotonic() - w0) / 1000) ns")
    }
    var callTimes: [Int64] = []
    for i in 0..<200 {
      let t = Clock.monotonic()
      let reply = try Channel.call(client, bytes: [0, 0, 0, 0, UInt8(truncatingIfNeeded: i)],
                                   deadline: Clock.monotonic() + 1000 * ms)
      callTimes.append(Clock.monotonic() - t)
      check(reply.bytes.count == 6 && reply.bytes[4] == UInt8(truncatingIfNeeded: i) && reply.bytes[5] == 0xEE,
            "call's reply")
    }
    callTimes.sort()
    print("sys-test: channel_call to another thread: median \(callTimes[100] / 1000) us, p90 \(callTimes[180] / 1000) us")
    _ = consume client
    try Thread.join(server)

    // A lock under contention from four threads.
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let lock = Lock()
    var workers: [UInt32] = []
    for _ in 0..<4 {
      workers.append(try Thread.spawn {
        for _ in 0..<5000 { lock.withLock { counter.value += 1 } }
      }.release())
    }
    for w in workers { try Thread.join(Handle(raw: w)) }
    check(counter.value == 20000, "lock counts")

    // Many short threads: their stacks are reaped as new ones start.
    for _ in 0..<64 {
      let t = try Thread.spawn {}
      try Thread.join(t)
    }

    // Futexes refuse a stale value and time out.
    let word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    unsafe word.pointee = 5
    check(status { () throws(Status) in try unsafe Futex.wait(word, current: 6) } == .badState, "futex value")
    check(status { () throws(Status) in try unsafe Futex.wait(word, current: 5, deadline: Clock.monotonic() + ms) } == .timedOut,
          "futex timeout")
    unsafe word.deallocate()

    // This process, and a job and process of its own making.
    let me = try Process.current()
    check(try me.info().type == ObjectType.process, "process self")
    // Resources (croi K9a): userboot passes each kind's ranged root on.
    try resources()

    // DMA (croi K9e): the stub IOMMU, a BTI narrowed, a contiguous VMO pinned.
    if let systemRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.system))) {
      let system = Handle(raw: systemRaw)
      let iommuResource = try Resource.create(parent: system, kind: .system, base: DMA.iommuSystemBase, size: 1,
                                              name: "sys-test iommu")
      let iommu = try DMA.stubIOMMU(resource: iommuResource)
      let bti = try DMA.bti(iommu: iommu, id: 0x42)
      try DMA.setProperties(bti, DMA.Properties(addressBits: 32))
      check(status { () throws(Status) in try DMA.setProperties(bti, DMA.Properties(addressBits: 48)) } == .accessDenied,
            "a BTI's properties only narrow")
      let buffer = try DMA.contiguousVMO(bti: bti, size: 65536)
      let pinned = try DMA.pin(bti, buffer, offset: 0, size: 65536, options: [.read, .write, .contiguous], count: 1)
      let bus = pinned.addresses[0]
      check(bus != 0 && bus & 4095 == 0 && bus + 65536 <= 1 << 32, "a contiguous pin under the BTI's 32 bits")
      let pages = try DMA.pin(bti, buffer, offset: 0, size: 8192, options: [.read], count: 2)
      check(pages.addresses == [bus, bus + 4096], "a page-by-page pin of the same memory")
      try DMA.unpin(pmt: pages.pmt)
      try DMA.unpin(pmt: pinned.pmt)
      print("sys-test: DMA: 64 KiB contiguous at \(hex(UInt32(truncatingIfNeeded: bus >> 16)))0000 through a no-IOMMU BTI")
    } else {
      check(false, "userboot's system resource")
    }

    // A virtual interrupt (croi K9c), taken by wait and through a port.
    let irq = try Interrupt.virtual()
    try Interrupt.trigger(irq, timestamp: 1234)
    check(try Interrupt.wait(irq) == 1234, "a virtual interrupt's timestamp, by wait")
    // Taken by a wait, it stays for the next wait: a port takes another.
    let bound = try Interrupt.virtual()
    let irqPort = try Port.create(bindToInterrupt: true)
    try Interrupt.bind(bound, port: irqPort, key: 77)
    try Interrupt.trigger(bound, timestamp: 5678)
    let ip = try Port.wait(irqPort, deadline: Clock.monotonic() + 1000 * ms)
    check(ip.key == 77 && ip.type == Interrupt.packetType && ip.payload.0 == 5678, "a virtual interrupt's packet")
    try Interrupt.ack(bound)
    let plain = try Interrupt.virtual()
    check(status { () throws(Status) in try Interrupt.bind(plain, port: port, key: 1) } != .ok,
          "a port not made for interrupts refuses them")
    print("sys-test: \(Clock.monotonic() - t0) ns")
  }
}
