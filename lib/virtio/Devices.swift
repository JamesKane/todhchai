// SPDX-License-Identifier: BSD-3-Clause

// What the other virtio devices' configurations say (Virtual I/O Device
// 1.2): network (§5.1), input (§5.8), GPU (§5.7) and sound (§5.14). Each
// reads only the configuration; their queues carry the rest, once croi's
// BTI lets the device reach memory.

/// Device ids (§5): a modern PCI device is 0x1040 plus the type; the
/// transitional ones below 0x1040 predate it.
public enum DeviceType {
  public static let network: UInt16 = 1
  public static let block: UInt16 = 2
  public static let gpu: UInt16 = 16
  public static let input: UInt16 = 18
  public static let sound: UInt16 = 25

  public static func modernID(_ type: UInt16) -> UInt16 { 0x1040 + type }
}

public enum Network {
  public enum Feature {
    public static let mtu: UInt64 = 1 << 3
    public static let mac: UInt64 = 1 << 5
    public static let status: UInt64 = 1 << 16
    public static let multiqueue: UInt64 = 1 << 22
  }

  public struct Config: Equatable, Sendable {
    public var mac: [UInt8]?
    /// Bit 0: the link is up.
    public var status: UInt16?
    public var mtu: UInt16?
    public var queuePairs: UInt16

    public init(mac: [UInt8]?, status: UInt16?, mtu: UInt16?, queuePairs: UInt16) {
      self.mac = mac
      self.status = status
      self.mtu = mtu
      self.queuePairs = queuePairs
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    let f = d.features
    return Config(
      mac: f & Feature.mac != 0 ? (0..<6).map { UInt8(truncatingIfNeeded: d.config($0, width: 1)) } : nil,
      status: f & Feature.status != 0 ? UInt16(truncatingIfNeeded: d.config(6, width: 2)) : nil,
      mtu: f & Feature.mtu != 0 ? UInt16(truncatingIfNeeded: d.config(10, width: 2)) : nil,
      queuePairs: f & Feature.multiqueue != 0 ? UInt16(truncatingIfNeeded: d.config(8, width: 2)) : 1)
  }

  /// `52:54:00:12:34:56`.
  public static func text(_ mac: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for (i, b) in mac.enumerated() {
      if i > 0 { out.append(UInt8(ascii: ":")) }
      out += [digits[Int(b >> 4)], digits[Int(b & 15)]]
    }
    return String(decoding: out, as: UTF8.self)
  }
}

public enum Input {
  /// virtio_input_config's select values (§5.8.4).
  public static let idName: UInt8 = 0x01
  public static let idSerial: UInt8 = 0x02
  public static let idDevids: UInt8 = 0x03
  public static let propBits: UInt8 = 0x10
  public static let eventBits: UInt8 = 0x11
  public static let absInfo: UInt8 = 0x12

  /// Asks the configuration (select, subsel) and reads the answer: `size`
  /// bytes of data at 8.
  public static func query<W: Window>(_ d: Device<W>, _ select: UInt8, _ subsel: UInt8 = 0) -> [UInt8] {
    d.setConfig(0, width: 1, UInt64(select))
    d.setConfig(1, width: 1, UInt64(subsel))
    let size = min(Int(d.config(2, width: 1)), 128)
    return (0..<size).map { UInt8(truncatingIfNeeded: d.config(8 + $0, width: 1)) }
  }

  public struct Identity: Equatable, Sendable {
    public var name: String
    public var bus: UInt16
    public var vendor: UInt16
    public var product: UInt16
    public var version: UInt16
    /// The event types it reports (EV_KEY 1, EV_REL 2, EV_ABS 3...).
    public var eventTypes: [UInt8]

    public init(name: String, bus: UInt16, vendor: UInt16, product: UInt16, version: UInt16, eventTypes: [UInt8]) {
      self.name = name
      self.bus = bus
      self.vendor = vendor
      self.product = product
      self.version = version
      self.eventTypes = eventTypes
    }
  }

  public static func identity<W: Window>(_ d: Device<W>) -> Identity {
    var nameBytes = query(d, idName)
    while nameBytes.last == 0 { nameBytes.removeLast() }  // QEMU counts the terminator
    let name = String(decoding: nameBytes, as: UTF8.self)
    let ids = query(d, idDevids)
    func le16(_ i: Int) -> UInt16 { i + 1 < ids.count ? UInt16(ids[i]) | UInt16(ids[i + 1]) << 8 : 0 }
    var types: [UInt8] = []
    for t in UInt8(1)..<0x20 where !query(d, eventBits, t).isEmpty { types.append(t) }
    return Identity(name: name, bus: le16(0), vendor: le16(2), product: le16(4), version: le16(6), eventTypes: types)
  }
}

public enum GPU {
  public enum Feature {
    public static let virgl: UInt64 = 1 << 0
    public static let edid: UInt64 = 1 << 1
    public static let resourceUUID: UInt64 = 1 << 2
    public static let resourceBlob: UInt64 = 1 << 3
  }

  public struct Config: Equatable, Sendable {
    public var scanouts: UInt32
    public var capsets: UInt32

    public init(scanouts: UInt32, capsets: UInt32) {
      self.scanouts = scanouts
      self.capsets = capsets
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    Config(scanouts: UInt32(truncatingIfNeeded: d.config(8, width: 4)),
           capsets: UInt32(truncatingIfNeeded: d.config(12, width: 4)))
  }
}

public enum Sound {
  public enum Feature {
    public static let controls: UInt64 = 1 << 0
  }

  public struct Config: Equatable, Sendable {
    public var jacks: UInt32
    public var streams: UInt32
    public var channelMaps: UInt32
    public var controls: UInt32?

    public init(jacks: UInt32, streams: UInt32, channelMaps: UInt32, controls: UInt32?) {
      self.jacks = jacks
      self.streams = streams
      self.channelMaps = channelMaps
      self.controls = controls
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    Config(jacks: UInt32(truncatingIfNeeded: d.config(0, width: 4)),
           streams: UInt32(truncatingIfNeeded: d.config(4, width: 4)),
           channelMaps: UInt32(truncatingIfNeeded: d.config(8, width: 4)),
           controls: d.features & Feature.controls != 0 ? UInt32(truncatingIfNeeded: d.config(12, width: 4)) : nil)
  }
}
