// SPDX-License-Identifier: BSD-3-Clause

// bin/devmgr (M3g, architecture §9): finds the machine's PCI functions over
// ECAM, binds drivers to them by the rules in lib/devmgr, and runs a driver
// host per bound device, given that device's resources and nothing more.
// Its manifest grants it MMIO (and on amd64 I/O port) resources and
// `programs`: bootfs and a job, under which it runs the hosts with
// lib/launch, so they restart by policy like any service.
//
//     arg --ecam BASE [--buses N]     # the ECAM window, until croi's K9b gives the MCFG
//
// Its tree:
//   status             a line a device: name, ids, class, driver host and state
//   enumeration        how long finding the functions took
//   drivers/SERVICE/   each driver host's own tree

import DevMgr
import IPC
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
      resource = try Resource.create(parent: root, kind: .mmio, base: base, size: UInt64(size), name: "ecam")
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

  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { fail("no Startup handle") }
    var start: Startup
    do { start = try Startup(Handle(raw: raw)) } catch { fail("can't read Startup") }
    var ecamBase: UInt64?
    var buses = 256
    var i = 0
    while i < start.args.count {
      let a = start.args[i]
      i += 1
      guard i < start.args.count, let v = number(start.args[i]) else { fail("bad arguments") }
      i += 1
      if a == "--ecam" { ecamBase = v } else if a == "--buses", v >= 1, v <= 256 { buses = Int(v) } else {
        fail("unknown argument \(a)")
      }
    }
    guard let ecamBase else { fail("no --ecam") }
    guard let mmioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (manifest: resource mmio)")
    }
    let ioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.ioport))) ?? 0
    let boot = Boot()

    // The functions, through ECAM.
    let t0 = Clock.monotonic()
    let window: Mapping
    do throws(Status) {
      window = try mapECAM(mmioRaw, base: ecamBase, buses: buses)
    } catch {
      fail("can't map ECAM at \(hex(UInt32(truncatingIfNeeded: ecamBase), digits: 8)): \(error)")
    }
    let mapped = Clock.monotonic() - t0
    let ecam = unsafe ECAM(unsafe: window.address, endBus: UInt8(buses - 1))
    let functions = enumerate(ecam)
    let enumerated = Clock.monotonic() - t0 - mapped
    let devices = functions.map { Device(pci: $0) }
    let bound = bind(devices, Drivers.rules)
    let entries = devices.indices.map { Entry(device: devices[$0], program: bound[$0].map { Drivers.rules[$0].program }) }
    print("devmgr: ECAM mapped in \(mapped / 1000) us; \(functions.count) PCI function(s) in \(enumerated / 1000) us, \(bound.filter { $0 != nil }.count) bound")

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
          let ids = e.device.pci.map { hex(UInt32($0.vendor), digits: 4) + ":" + hex(UInt32($0.device), digits: 4) } ?? "-"
          let cls = e.device.pci.map {
            hex(UInt32($0.classCode), digits: 2) + "." + hex(UInt32($0.subclass), digits: 2) + "."
              + hex(UInt32($0.progIF), digits: 2)
          } ?? "-"
          return "\(e.device.name) \(ids) \(cls) \(e.service ?? "-") \(e.state)\n"
        }.joined()
      }
    })
    tree.text("enumeration", read: { "ECAM mapped in \(mapped) ns, \(functions.count) functions in \(enumerated) ns\n" })

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
      let made = try? grants(for: f, ecam: ecamBase, startBus: 0, mmio: mmio, ioports: io)
      _ = mmio.release()
      if let io { _ = io.release() }
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
