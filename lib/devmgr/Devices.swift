// SPDX-License-Identifier: BSD-3-Clause

// devmgr's model (architecture §9): the devices enumeration found, PCI
// functions and ACPI's present devices, and the rules that bind drivers
// to them. A rule is a Swift predicate over a
// device, compiled into devmgr (Rules.swift), not a table a driver
// carries: the first rule that matches names the program a driver host
// runs for the device.

import PCI

public struct Device: Sendable {
  /// An ACPI device: its namespace path (`\\_SB_.PCI0.SF8_.RTC_`), its
  /// hardware id and compatible ids (`PNP0B00`, `ACPI0007`), and _STA.
  public struct ACPIDevice: Equatable, Sendable {
    public var path: String
    public var hid: String?
    public var cids: [String]
    public var status: UInt64

    public init(path: String, hid: String?, cids: [String], status: UInt64) {
      self.path = path
      self.hid = hid
      self.cids = cids
      self.status = status
    }
  }

  public enum Bus: Sendable {
    case pci(Function)
    case acpi(ACPIDevice)
  }

  public var bus: Bus

  public init(pci: Function) { bus = .pci(pci) }
  public init(acpi: ACPIDevice) { bus = .acpi(acpi) }

  /// The PCI function, if it is one.
  public var pci: Function? {
    switch bus {
    case .pci(let f): f
    case .acpi: nil
    }
  }

  /// The ACPI device, if it is one.
  public var acpi: ACPIDevice? {
    switch bus {
    case .pci: nil
    case .acpi(let d): d
    }
  }

  /// A name for the device's node and its driver host's service:
  /// `pci-bb:dd.f`, or `acpi-` and the path without its root
  /// (`acpi-_SB_.PCI0.SF8_.RTC_`).
  public var name: String {
    switch bus {
    case .pci(let f): "pci-" + f.address.description
    case .acpi(let d): "acpi-" + String(decoding: d.path.utf8.drop { $0 == UInt8(ascii: "\\") }, as: UTF8.self)
    }
  }

  /// Its ids for devmgr's status: `vvvv:dddd` or the HID.
  public var ids: String {
    switch bus {
    case .pci(let f): hex(UInt32(f.vendor), digits: 4) + ":" + hex(UInt32(f.device), digits: 4)
    case .acpi(let d): d.hid ?? "-"
    }
  }

  public var description: String {
    switch bus {
    case .pci(let f): "pci " + f.description
    case .acpi(let d): "acpi " + d.path + " " + (d.hid ?? "-")
    }
  }
}

/// A driver's bind rule: the program (bootfs's `bin/NAME`) a driver host
/// runs for each device the predicate accepts.
public struct DriverRule: Sendable {
  public let program: String
  public let matches: @Sendable (Device) -> Bool

  public init(program: String, matches: @escaping @Sendable (Device) -> Bool) {
    self.program = program
    self.matches = matches
  }

  /// A rule for an ACPI hardware or compatible id.
  public static func acpi(_ program: String, id: String) -> DriverRule {
    DriverRule(program: program) { d in d.acpi.map { $0.hid == id || $0.cids.contains(id) } ?? false }
  }

  /// A rule for a PCI vendor and device id.
  public static func pci(_ program: String, vendor: UInt16, device: UInt16) -> DriverRule {
    DriverRule(program: program) { d in d.pci.map { $0.vendor == vendor && $0.device == device } ?? false }
  }
}

/// Each device's rule: the first that matches it, or nil.
public func bind(_ devices: [Device], _ rules: [DriverRule]) -> [Int?] {
  devices.map { d in rules.firstIndex { $0.matches(d) } }
}
