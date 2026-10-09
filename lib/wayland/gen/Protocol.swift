// SPDX-License-Identifier: BSD-3-Clause

// A Wayland protocol definition, read from its XML (the format described in
// the Wayland documentation, "Wire Format" and "Protocol XML").

public struct ProtocolDefinition: Sendable {
  public var name: String
  public var interfaces: [Interface]
}

public struct Interface: Sendable {
  public var name: String
  public var version: Int
  public var requests: [Message]
  public var events: [Message]
  public var enums: [Enumeration]
}

public struct Message: Sendable {
  public var name: String
  public var since: Int
  public var isDestructor: Bool
  public var arguments: [Argument]
}

public struct Argument: Sendable {
  public enum Kind: String, Sendable {
    case int, uint, fixed, string, object
    case newID = "new_id"
    case array, fd
  }
  public var name: String
  public var kind: Kind
  public var interface: String?
  public var allowNull: Bool
  public var enumeration: String?
}

public struct Enumeration: Sendable {
  public var name: String
  public var bitfield: Bool
  public var entries: [(name: String, value: UInt32)]
}

public func readProtocol(_ text: String) throws(XMLError) -> ProtocolDefinition {
  let root = try parseXML(text)
  guard root.name == "protocol", let name = root.attribute("name") else {
    throw XMLError(description: "not a Wayland protocol (no <protocol name=...>)")
  }
  var interfaces: [Interface] = []
  for i in root.elements("interface") {
    guard let iname = i.attribute("name"), let version = i.attribute("version").flatMap(Int.init) else {
      throw XMLError(description: "an interface without a name or version")
    }
    func messages(_ tag: String) throws(XMLError) -> [Message] {
      var out: [Message] = []
      for m in i.elements(tag) {
        guard let mname = m.attribute("name") else { throw XMLError(description: "\(iname): a \(tag) without a name") }
        var arguments: [Argument] = []
        for a in m.elements("arg") {
          guard let aname = a.attribute("name"), let kind = a.attribute("type").flatMap(Argument.Kind.init) else {
            throw XMLError(description: "\(iname).\(mname): an argument without a name or known type")
          }
          arguments.append(Argument(name: aname, kind: kind, interface: a.attribute("interface"),
                                    allowNull: a.attribute("allow-null") == "true", enumeration: a.attribute("enum")))
        }
        out.append(Message(name: mname, since: m.attribute("since").flatMap(Int.init) ?? 1,
                           isDestructor: m.attribute("type") == "destructor", arguments: arguments))
      }
      return out
    }
    var enums: [Enumeration] = []
    for e in i.elements("enum") {
      guard let ename = e.attribute("name") else { throw XMLError(description: "\(iname): an enum without a name") }
      var entries: [(String, UInt32)] = []
      for entry in e.elements("entry") {
        guard let n = entry.attribute("name"), let v = entry.attribute("value") else { continue }
        let value = v.hasPrefix("0x") ? UInt32(v.dropFirst(2), radix: 16) : UInt32(v)
        guard let value else { throw XMLError(description: "\(iname).\(ename).\(n): value \(v)") }
        entries.append((n, value))
      }
      enums.append(Enumeration(name: ename, bitfield: e.attribute("bitfield") == "true", entries: entries))
    }
    interfaces.append(Interface(name: iname, version: version, requests: try messages("request"),
                                events: try messages("event"), enums: enums))
  }
  return ProtocolDefinition(name: name, interfaces: interfaces)
}
