// SPDX-License-Identifier: BSD-3-Clause

// The protocol as the macro and idlc see it: methods, their
// parameters and results, each field's wire type and place in the inline
// part (docs/wire-format.md).

import IPCWire

/// A field's type on the wire.
public enum WireType: Equatable {
  case integer(String, size: Int)  // the Swift type name, its byte size
  case bool
  case string
  case handle

  public init?(swiftType: String) {
    switch swiftType {
    case "UInt8", "Int8": self = .integer(swiftType, size: 1)
    case "UInt16", "Int16": self = .integer(swiftType, size: 2)
    case "UInt32", "Int32": self = .integer(swiftType, size: 4)
    case "UInt64", "Int64": self = .integer(swiftType, size: 8)
    case "Bool": self = .bool
    case "String": self = .string
    case "Handle": self = .handle
    default: return nil
    }
  }

  public var size: Int {
    switch self {
    case .integer(_, let size): size
    case .bool: 1
    case .string: 16
    case .handle: 4
    }
  }

  public var alignment: Int {
    switch self {
    case .integer(_, let size): size
    case .bool: 1
    case .string: 8
    case .handle: 4
    }
  }
}

/// A field in an inline part: where it is and what it holds.
public struct Field {
  public var name: String  // the Swift name used in generated code
  public var type: WireType
  public var offset: Int
}

/// Fields laid out in order, each naturally aligned; the padding between
/// them, and the part's size rounded up to 8.
public struct Layout {
  public var fields: [Field] = []
  public var padding: [(offset: Int, count: Int)] = []
  public var size = 0

  public init(_ members: [(name: String, type: WireType)]) {
    var end = 0
    for member in members {
      let offset = (end + member.type.alignment - 1) / member.type.alignment * member.type.alignment
      if offset > end { padding.append((end, offset - end)) }
      fields.append(Field(name: member.name, type: member.type, offset: offset))
      end = offset + member.type.size
    }
    size = wireAligned(end)
    if size > end { padding.append((end, size - end)) }
  }
}

/// A method's parameter.
public struct Parameter {
  public var label: String?  // nil for `_`
  public var name: String
  public var swiftType: String  // as written, without `consuming`
  public var type: WireType
}

/// What a method is.
public enum MethodKind {
  case call  // request and reply
  case oneway  // request only
  case event  // sent by the server
}

/// A method of the protocol.
public struct Method {
  public var name: String
  public var kind: MethodKind
  public var since: Int
  public var parameters: [Parameter]
  public var result: (swiftType: String, type: WireType)?
  public var errorType: String?  // the `throws(E)` type, if any
  public var ordinal: UInt64

  public var request: Layout { Layout(parameters.map { ("a_\($0.name)", $0.type) }) }
  public var reply: Layout { Layout(result.map { [("r", $0.type)] } ?? []) }
}

/// The ordinal of `method` in protocol `id` (docs/wire-format.md).
public func ordinal(protocolID id: String, method: String) -> UInt64 {
  let name = Array("\(id).\(method)".utf8)
  return methodOrdinal(name.span)
}
