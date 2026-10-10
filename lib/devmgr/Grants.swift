// SPDX-License-Identifier: BSD-3-Clause

// What a driver host is given for its device (architecture §9: exactly
// the MMIO, IRQ, BTI and I/O port handles for it): a resource for each
// BAR, MMIO or I/O ports as the BAR is, and an MMIO resource over the
// function's 4 KiB of ECAM, and an IRQ resource for the GSI its interrupt
// pin is routed to (Routing.swift), and a BTI for its DMA (croi K9e: under
// the stub IOMMU, narrowed to the device's address width). They come as
// startup handles of type `HandleType.device`, whose argument says which:
// 0-5 the BAR of that index, `configSpace` the configuration space,
// `interruptBase` plus the trigger mode the interrupt, `dmaBTI` the BTI.

import PCI
import Sys
import _Volatile

public enum DeviceHandle {
  /// The argument of the configuration space's resource.
  public static let configSpace: UInt32 = 0x10

  /// The interrupt's argument, plus its mode's value (Interrupt.Mode).
  public static let interruptBase: UInt32 = 0x100
  public static let dmaBTI: UInt32 = 0x20
  public static var bti: UInt32 { HandleType.info(HandleType.device, dmaBTI) }

  public static func bar(_ index: Int) -> UInt32 { HandleType.info(HandleType.device, UInt32(index)) }
  public static var config: UInt32 { HandleType.info(HandleType.device, configSpace) }
  public static func interrupt(_ mode: Interrupt.Mode) -> UInt32 {
    HandleType.info(HandleType.device, interruptBase + mode.rawValue)
  }
}

/// The resources for function `f`, made under devmgr's MMIO and I/O port
/// ranged roots, with their startup info words. `ecam` is the physical
/// address of bus `startBus`'s window. A BAR whose kind devmgr has no root
/// for (I/O ports off amd64) is left out.
public func grants(for f: Function, ecam: UInt64, startBus: UInt8, mmio: borrowing Handle, ioports: borrowing Handle?,
                   interrupt: InterruptRoute? = nil, irqs: borrowing Handle? = nil,
                   iommu: borrowing Handle? = nil, addressBits: UInt32 = 64)
  throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  func add(_ info: UInt32, _ make: () throws(Status) -> Handle) throws(Status) {
    do throws(Status) {
      out.append((info, try make().release()))
    } catch {
      for e in out { close(raw: e.handle) }
      throw error
    }
  }
  let name = f.address.description
  for bar in f.bars {
    switch bar.space {
    case .memory:
      try add(DeviceHandle.bar(bar.index)) { () throws(Status) in
        try Resource.create(parent: mmio, kind: .mmio, base: bar.address, size: bar.size, name: "\(name) bar\(bar.index)")
      }
    case .io:
      switch ioports {
      case .some(let ports):
        try add(DeviceHandle.bar(bar.index)) { () throws(Status) in
          try Resource.create(parent: ports, kind: .ioport, base: bar.address, size: bar.size,
                              name: "\(name) bar\(bar.index)")
        }
      case .none: break
      }
    }
  }
  let config = ecam + UInt64(ECAM.offset(bus: Int(f.address.bus - startBus), device: f.address.device,
                                         function: f.address.function))
  try add(DeviceHandle.config) { () throws(Status) in
    try Resource.create(parent: mmio, kind: .mmio, base: config, size: 4096, name: "\(name) config")
  }
  if let interrupt {
    switch irqs {
    case .some(let root):
      try add(DeviceHandle.interrupt(interrupt.mode)) { () throws(Status) in
        try Resource.create(parent: root, kind: .irq, base: UInt64(interrupt.gsi), size: 1, name: "\(name) irq")
      }
    case .none: break
    }
  }
  switch iommu {
  case .some(let iommu):
    let a = f.address
    try add(DeviceHandle.bti) { () throws(Status) in
      let bti = try DMA.bti(iommu: iommu, id: UInt64(a.segment) << 16 | UInt64(a.bus) << 8 | UInt64(a.device) << 3
                              | UInt64(a.function))
      if addressBits < 64 { try DMA.setProperties(bti, DMA.Properties(addressBits: addressBits)) }
      return bti
    }
  case .none: break
  }
  return out
}

/// A driver host's device: the resources it was started with, taken by
/// their info words (natively `StartupHandles.take`).
public struct DeviceResources: ~Copyable {
  var bars: [(index: Int, handle: UInt32)] = []
  var config: UInt32 = 0
  var irq: UInt32 = 0
  var bti: UInt32 = 0
  /// The interrupt's trigger mode, if one was granted.
  public private(set) var interruptMode: Interrupt.Mode?

  public init(take: (UInt32) -> UInt32?) {
    for i in 0..<6 {
      if let h = take(DeviceHandle.bar(i)) { bars.append((i, h)) }
    }
    config = take(DeviceHandle.config) ?? 0
    bti = take(DeviceHandle.bti) ?? 0
    for mode in [Interrupt.Mode.default, .edgeLow, .edgeHigh, .levelLow, .levelHigh] {
      if let h = take(DeviceHandle.interrupt(mode)) {
        irq = h
        interruptMode = mode
      }
    }
  }

  deinit {
    for b in bars { close(raw: b.handle) }
    if config != 0 { close(raw: config) }
    if irq != 0 { close(raw: irq) }
    if bti != 0 { close(raw: bti) }
  }

  /// The device's BTI, which the caller owns from then on.
  public mutating func takeBTI() -> Handle? {
    guard bti != 0 else { return nil }
    let h = Handle(raw: bti)
    bti = 0
    return h
  }

  /// The interrupt's number (the GSI), if one was granted.
  public func interruptNumber() throws(Status) -> UInt32 {
    guard irq != 0 else { throw .notFound }
    return try borrowed(irq) { (h: borrowing Handle) throws(Status) in UInt32(truncatingIfNeeded: try Resource.info(h).base) }
  }

  /// The device's interrupt object.
  public func interrupt() throws(Status) -> Handle {
    guard irq != 0, let mode = interruptMode else { throw .notFound }
    let number = try interruptNumber()
    return try borrowed(irq) { (h: borrowing Handle) throws(Status) in
      try Interrupt.create(resource: h, number: number, mode: mode)
    }
  }

  /// The BARs it may use.
  public var barIndices: [Int] { bars.map { $0.index } }

  /// What resource `index` grants: base and size, and whether it is I/O ports.
  public func bar(_ index: Int) throws(Status) -> ResourceInfo {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try borrowed(raw) { (h: borrowing Handle) throws(Status) in try Resource.info(h) }
  }

  /// Calls `body` with BAR `index`'s resource, which stays this value's.
  public func borrowedBAR<R: ~Copyable>(_ index: Int, _ body: (borrowing Handle) throws(Status) -> R) throws(Status) -> R {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try borrowed(raw, body)
  }

  /// BAR `index` (memory) mapped uncached, as device registers are.
  public func map(bar index: Int) throws(Status) -> Registers {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try map(raw)
  }

  /// The function's configuration space, mapped.
  public func mapConfig() throws(Status) -> Registers {
    guard config != 0 else { throw .notFound }
    return try map(config)
  }

  func map(_ raw: UInt32) throws(Status) -> Registers {
    try borrowed(raw) { (h: borrowing Handle) throws(Status) in
      let info = try Resource.info(h)
      guard info.kind == ResourceKind.mmio.rawValue else { throw .wrongType }
      let base = info.base & ~4095
      let size = Int((info.base - base + info.size + 4095) & ~4095)
      let vmo = try VMO.physical(resource: h, address: base, size: size)
      return Registers(try VMO.map(vmo, length: size), offset: Int(info.base - base), size: Int(info.size))
    }
  }

  func borrowed<R: ~Copyable>(_ raw: UInt32, _ body: (borrowing Handle) throws(Status) -> R) throws(Status) -> R {
    let h = Handle(raw: raw)  // still owned by the DeviceResources
    let result: Result<R, Status>
    do throws(Status) { result = .success(try body(h)) } catch { result = .failure(error) }
    _ = h.release()
    return try result.get()
  }
}

/// A device's registers, mapped: loads and stores are volatile, each made
/// once and in order, at offsets from the window's start.
@safe public struct Registers: ~Copyable {
  let mapping: Mapping
  let offset: Int
  public let size: Int

  init(_ mapping: consuming Mapping, offset: Int, size: Int) {
    self.mapping = mapping
    self.offset = offset
    self.size = size
  }

  func at<T>(_ o: Int, _: T.Type) -> UInt {
    precondition(o >= 0 && o + MemoryLayout<T>.size <= size && o % MemoryLayout<T>.size == 0)
    return unsafe UInt(bitPattern: mapping.address) + UInt(offset + o)
  }

  public func load32(_ o: Int) -> UInt32 { unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: at(o, UInt32.self)).load() }
  public func load16(_ o: Int) -> UInt16 { unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: at(o, UInt16.self)).load() }
  public func load8(_ o: Int) -> UInt8 { unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: at(o, UInt8.self)).load() }
  public func store32(_ o: Int, _ v: UInt32) {
    unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: at(o, UInt32.self)).store(v)
  }
  public func store16(_ o: Int, _ v: UInt16) {
    unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: at(o, UInt16.self)).store(v)
  }
  public func store8(_ o: Int, _ v: UInt8) { unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: at(o, UInt8.self)).store(v) }
}
