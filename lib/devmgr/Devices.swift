// SPDX-License-Identifier: BSD-3-Clause

// devmgr's model (architecture §9): the devices enumeration found, and the
// rules that bind drivers to them. A rule is a Swift predicate over a
// device, compiled into devmgr (Rules.swift), not a table a driver
// carries: the first rule that matches names the program a driver host
// runs for the device.

import PCI

public struct Device: Sendable {
  public enum Bus: Sendable {
    case pci(Function)
  }

  public var bus: Bus

  public init(pci: Function) { bus = .pci(pci) }

  /// The PCI function, if it is one.
  public var pci: Function? {
    switch bus {
    case .pci(let f): f
    }
  }

  /// A name for the device's node and its driver host's service:
  /// `pci-bb:dd.f`.
  public var name: String {
    switch bus {
    case .pci(let f): "pci-" + f.address.description
    }
  }

  public var description: String {
    switch bus {
    case .pci(let f): "pci " + f.description
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

  /// A rule for a PCI vendor and device id.
  public static func pci(_ program: String, vendor: UInt16, device: UInt16) -> DriverRule {
    DriverRule(program: program) { d in d.pci.map { $0.vendor == vendor && $0.device == device } ?? false }
  }
}

/// Each device's rule: the first that matches it, or nil.
public func bind(_ devices: [Device], _ rules: [DriverRule]) -> [Int?] {
  devices.map { d in rules.firstIndex { $0.matches(d) } }
}
