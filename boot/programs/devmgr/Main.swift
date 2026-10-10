// SPDX-License-Identifier: BSD-3-Clause

// bin/devmgr (M3g, architecture §9): finds the machine's PCI functions over
// ECAM, binds drivers to them by the rules in lib/devmgr, and runs a driver
// host per bound device, given that device's resources and nothing more.
// Its manifest grants it MMIO (and on amd64 I/O port) resources and
// `programs`: bootfs and a job, under which it runs the hosts with
// lib/launch, so they restart by policy like any service.
//
//     arg [--ecam BASE] [--buses N]   # the ECAM window, if not the MCFG's
//
// It reads the firmware's tables from the RSDP in croi's boot data
// (`bootdata`, K9b), takes ECAM's window from the MCFG, and loads ACPI's
// namespace with our AML interpreter, its regions over this machine
// (lib/devmgr/Firmware.swift), before it enumerates PCI (M3h).
//
// Its tree:
//   status             a line a device: name, ids, class, driver host and state
//   enumeration        how long finding the PCI functions took
//   acpi               the tables, and how long loading and _STA took
//   drivers/SERVICE/   each driver host's own tree

import DevMgr
import IPC
import TDACPI
import ZBI
import Launch
import LibSys
import Node
import PCI
import Sys

@main struct DevMgrProgram {
  static func fail(_ what: String) -> Never {
    print("devmgr: \(what)")
    exit(1)
  }

  /// A number in decimal or 0x-prefixed hexadecimal.
  static func number(_ text: String) -> UInt64? {
    let bytes = Array(text.utf8)
    if bytes.count > 2, bytes[0] == UInt8(ascii: "0"), bytes[1] | 0x20 == UInt8(ascii: "x") {
      var v: UInt64 = 0
      for b in bytes.dropFirst(2) {
        let d: UInt8
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): d = b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): d = b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): d = b - UInt8(ascii: "A") + 10
        default: return nil
        }
        v = v << 4 | UInt64(d)
      }
      return v
    }
    return UInt64(text)
  }

  /// The ECAM window for `buses` buses at `base`, through a resource made
  /// under devmgr's MMIO root (`mmio`, which stays devmgr's).
  static func mapECAM(_ mmio: UInt32, base: UInt64, buses: Int) throws(Status) -> Mapping {
    let root = Handle(raw: mmio)
    let size = ECAM.size(buses: buses)
    let resource: Handle
    do throws(Status) {
      resource = try Sys.Resource.create(parent: root, kind: .mmio, base: base, size: UInt64(size), name: "ecam")
    } catch {
      _ = root.release()
      throw error
    }
    _ = root.release()
    return try VMO.map(try VMO.physical(resource: resource, address: base, size: size), length: size)
  }

  /// A device and what devmgr did about it.
  final class Entry: @unchecked Sendable {
    let device: Device
    let program: String?
    var state: String
    init(device: Device, program: String?) {
      self.device = device
      self.program = program
      state = program == nil ? "unbound" : "not started"
    }
    var service: String? { program.map { "\($0)-" + (device.pci?.address.description ?? device.name) } }
  }

  /// The firmware's tables, from the RSDP in the boot data.
  static func tables(_ data: BootData, _ memory: PhysicalMemory) -> TableSet? {
    guard let at = data.rsdp, let bytes = memory.bytes(at, 36), let rsdp = try? RSDP(bytes) else { return nil }
    return try? TableSet(rsdp: rsdp, read: { memory.bytes($0, $1) })
  }

  /// What ACPI found, and how long each part took.
  struct ACPIResult {
    var devices: [Device.ACPIDevice] = []
    var routes: [InterruptRoute] = []
    var summary = "no ACPI tables\n"
  }

  /// Loads the DSDT and SSDTs with load-time code run over the machine
  /// (`host`), runs _INI, and reads every device's _STA, HID and CIDs.
  static func loadNamespace<C: ConfigSpace>(_ set: TableSet, host: MachineHost<C>) -> ACPIResult {
    var result = ACPIResult()
    let aml = ([set.dsdt].compactMap { $0 } + set.ssdts)
    let t0 = Clock.monotonic()
    var ns = Namespace(integerBits: set.integerBits)
    var loadFailures = 0
    for t in aml where (try? ns.load(t, host: host)) == nil { loadFailures += 1 }
    let t1 = Clock.monotonic()
    // The APIC model, before _INI and _PRT (whose answers depend on it).
    let picFailed = (try? ns.useAPIC(host: host)) == nil
    let initFailed = ns.initializeDevices(host: host)
    let initFailures = initFailed.count
    let t2 = Clock.monotonic()
    let nodes = ns.deviceNodes()
    var statuses: [(node: Int, status: UInt64)] = []
    for d in nodes { statuses.append((d, (try? ns.status(d, host: host))?.raw ?? 0)) }
    let t3 = Clock.monotonic()
    for (d, status) in statuses where status & 1 != 0 {
      let hid = (try? ns.hardwareID(d, host: host)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
      let cids = ((try? ns.compatibleIDs(d, host: host)) ?? []).map { String(decoding: $0, as: UTF8.self) }
      result.devices.append(Device.ACPIDevice(path: String(decoding: ns.path(d), as: UTF8.self), hid: hid, cids: cids,
                                              status: status))
    }
    let t4 = Clock.monotonic()
    let routesFailed: Bool
    do throws(ACPIError) {
      result.routes = try ns.interruptRoutes(host: host)
      routesFailed = false
    } catch {
      routesFailed = true
    }
    let t5 = Clock.monotonic()
    let bytes = aml.reduce(0) { $0 + $1.length }
    result.summary = "\(set.tables.count) tables, \(aml.count) with AML (\(bytes) bytes), \(ns.nodes.count) nodes\n"
      + "load \((t1 - t0) / 1000) us (\(loadFailures) failed), _INI \((t2 - t1) / 1000) us (\(initFailures) failed)\n"
      + "_STA on \(nodes.count) devices \((t3 - t2) / 1000) us, \(result.devices.count) present\n"
      + "_PIC(1) \(picFailed ? "failed" : "ok"), _PRT \(result.routes.count) routes \((t5 - t4) / 1000) us\(routesFailed ? " (failed)" : "")\n"
      + initFailed.map { "_INI failed: \(String(decoding: ns.path($0.device), as: UTF8.self)) \($0.error.name)\n" }.joined()
      + statuses.filter { $0.status & 1 == 0 }.map { "absent: \(String(decoding: ns.path($0.node), as: UTF8.self))\n" }
      .joined()
      + host.log.map { "aml: \($0)\n" }.joined()
    return result
  }

  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { fail("no Startup handle") }
    var start: Startup
    do { start = try Startup(Handle(raw: raw)) } catch { fail("can't read Startup") }
    var ecamArgument: UInt64?
    var buses = 256
    var i = 0
    while i < start.args.count {
      let a = start.args[i]
      i += 1
      guard i < start.args.count, let v = number(start.args[i]) else { fail("bad arguments") }
      i += 1
      if a == "--ecam" { ecamArgument = v } else if a == "--buses", v >= 1, v <= 256 { buses = Int(v) } else {
        fail("unknown argument \(a)")
      }
    }
    guard let mmioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (manifest: resource mmio)")
    }
    let ioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.ioport))) ?? 0
    let irqRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.irq))) ?? 0
    // The stub IOMMU, for the hosts' BTIs (croi K9e), if `resource system` is granted.
    var iommuRaw: UInt32 = 0
    if let systemRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.system))) {
      let system = Handle(raw: systemRaw)
      if let r = try? Sys.Resource.create(parent: system, kind: .system, base: DMA.iommuSystemBase, size: 1, name: "iommu"),
        let iommu = try? DMA.stubIOMMU(resource: r)
      {
        iommuRaw = iommu.release()
      }
    }
    let boot = Boot()
    let memory = PhysicalMemory(mmioRoot: mmioRaw)
    let ports = ioRaw != 0 ? PortSpace(ioportRoot: ioRaw) : nil

    // The firmware's tables, through croi's boot data (K9b).
    let t0 = Clock.monotonic()
    var data = BootData()
    if let raw = StartupHandles.take(ProcessArgs.info(HandleType.vmoBootData)) {
      let vmo = Handle(raw: raw)
      if let header = try? VMO.read(vmo, offset: 0, count: BootData.headerSize),
        let length = try? BootData.length(header: header), let bytes = try? VMO.read(vmo, offset: 0, count: length),
        let read = try? BootData(bytes)
      {
        data = read
      } else {
        print("devmgr: the boot data is malformed")
      }
    }
    let tableSet = tables(data, memory)
    let tablesRead = Clock.monotonic() - t0

    // ECAM: the MCFG's first window, or --ecam.
    var ecamBase: UInt64, startBus: UInt8 = 0
    if let ecamArgument {
      ecamBase = ecamArgument
    } else if let t = tableSet?.table(MCFG.signature), let w = (try? MCFG(t))?.windows.first(where: { $0.segment == 0 }) {
      ecamBase = w.base
      startBus = w.startBus
      buses = min(buses, Int(w.endBus) - Int(w.startBus) + 1)
    } else {
      fail("no MCFG and no --ecam: can't reach PCI")
    }
    let t1 = Clock.monotonic()
    let window: Mapping
    do throws(Status) {
      window = try mapECAM(mmioRaw, base: ecamBase, buses: buses)
    } catch {
      fail("can't map ECAM at \(hex(UInt32(truncatingIfNeeded: ecamBase), digits: 8)): \(error)")
    }
    let mapped = Clock.monotonic() - t1
    let ecam = unsafe ECAM(unsafe: window.address, startBus: startBus, endBus: UInt8(Int(startBus) + buses - 1))

    // ACPI's namespace, its regions over this machine.
    let host = MachineHost(
      readMemory: { memory.read($0, width: $1) }, writeMemory: { memory.write($0, width: $1, $2) },
      readPort: ports.map { p in { p.read($0, width: $1) } }, writePort: ports.map { p in { p.write($0, width: $1, $2) } },
      config: ecam)
    let acpi = tableSet.map { loadNamespace($0, host: host) } ?? ACPIResult()
    for line in ("tables read in \(tablesRead / 1000) us\n" + acpi.summary).split(separator: "\n") { print("devmgr: acpi: \(line)") }

    // The PCI functions.
    let t2 = Clock.monotonic()
    let functions = enumerate(ecam, bus: startBus)
    let enumerated = Clock.monotonic() - t2
    let devices = functions.map { Device(pci: $0) } + acpi.devices.map { Device(acpi: $0) }
    let bound = bind(devices, Drivers.rules)
    let entries = devices.indices.map { Entry(device: devices[$0], program: bound[$0].map { Drivers.rules[$0].program }) }
    print("devmgr: ECAM at \(hex(UInt32(truncatingIfNeeded: ecamBase), digits: 8)) mapped in \(mapped / 1000) us; \(functions.count) PCI function(s) in \(enumerated / 1000) us; \(bound.filter { $0 != nil }.count) device(s) bound")

    // A bound function decodes its BARs; bus mastering is its driver's to turn on.
    for e in entries where e.program != nil {
      guard let f = e.device.pci else { continue }
      var command = ecam.read16(f.address, Register.command)
      if f.bars.contains(where: { $0.space == .memory }) { command |= Command.memory }
      if f.bars.contains(where: { $0.space == .io }) { command |= Command.io }
      ecam.write16(f.address, Register.command, command)
    }

    let dispatcher: IPCDispatcher
    do { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let lock = Lock()
    tree.text("status", read: {
      lock.withLock {
        entries.map { e in
          let ids = e.device.ids
          let cls = e.device.pci.map {
            hex(UInt32($0.classCode), digits: 2) + "." + hex(UInt32($0.subclass), digits: 2) + "."
              + hex(UInt32($0.progIF), digits: 2)
          } ?? "-"
          return "\(e.device.name) \(ids) \(cls) \(e.service ?? "-") \(e.state)\n"
        }.joined()
      }
    })
    tree.text("enumeration", read: { "ECAM mapped in \(mapped) ns, \(functions.count) functions in \(enumerated) ns\n" })
    let acpiSummary = "tables read in \(tablesRead / 1000) us\n" + acpi.summary
      + "physical pages mapped \(memory.mappedPages)\n"
    tree.text("acpi", read: { acpiSummary })

    // Driver hosts, each a service of devmgr's own launcher.
    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: boot.programs, rootJob: boot.job)
    } catch {
      fail("can't make a launcher: \(error)")
    }
    launcher.extraStartupHandles = { service in
      guard let e = entries.first(where: { $0.service == service }), let f = e.device.pci else { return [] }
      let mmio = Handle(raw: mmioRaw)
      let io: Handle? = ioRaw != 0 ? Handle(raw: ioRaw) : nil
      let irqs: Handle? = irqRaw != 0 ? Handle(raw: irqRaw) : nil
      let iommu: Handle? = iommuRaw != 0 ? Handle(raw: iommuRaw) : nil
      let bits = e.program.flatMap { p in Drivers.rules.first { $0.program == p } }?.addressBits ?? 64
      // The root bus's slots, through _PRT.
      let route = f.address.bus == startBus
        ? acpi.routes.first { $0.slot == f.address.device && $0.pin == f.interruptPin } : nil
      let made = try? grants(for: f, ecam: ecamBase, startBus: startBus, mmio: mmio, ioports: io, interrupt: route,
                             irqs: irqs, iommu: iommu, addressBits: bits)
      _ = mmio.release()
      if let io { _ = io.release() }
      if let irqs { _ = irqs.release() }
      if let iommu { _ = iommu.release() }
      return made ?? []
    }
    for e in entries {
      guard let program = e.program, let service = e.service else { continue }
      let manifest = "service \(service)\nprogram \(program)\nexport\nrestart on-failure\n"
      do throws(LaunchError) {
        try launcher.start([(path: "devmgr/\(service)", text: manifest)])
        tree.mount("drivers/\(service)", try launcher.channel(to: service))
        lock.withLock { e.state = "running" }
      } catch {
        lock.withLock { e.state = "failed" }
        print("devmgr: \(service): \(error.description)")
      }
    }

    do {
      try tree.serve(try start.export())
      try start.ready()
    } catch {
      fail("can't serve")
    }
    _ = try? dispatcher.run()  // until the launcher ends it
    _ = consume window
    _ = consume boot
  }
}
