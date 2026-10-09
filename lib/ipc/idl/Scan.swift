// SPDX-License-Identifier: BSD-3-Clause

// Finds the @IPCProtocol protocols in Swift source files, and the error
// enums their methods throw, so idlc can describe them in C and Markdown.

import IPCModel
import SwiftParser
import SwiftSyntax

/// An error enum's cases and their codes, when its source is at hand.
public struct ErrorEnum {
  public var name: String
  public var cases: [(name: String, code: Int32)]
}

/// Everything idlc reads from a set of files.
public struct Interface {
  public var protocols: [ProtocolModel] = []
  public var errors: [String: ErrorEnum] = [:]
}

/// A protocol idlc couldn't read, with where it is.
public struct IDLError: Error, CustomStringConvertible {
  public let description: String
}

/// Reads every @IPCProtocol protocol and every Int32 enum in `sources`
/// (path, contents).
public func scan(_ sources: [(path: String, text: String)]) throws(IDLError) -> Interface {
  var interface = Interface()
  for (path, text) in sources {
    let file = Parser.parse(source: text)
    for statement in file.statements {
      if let proto = statement.item.as(ProtocolDeclSyntax.self),
        let attribute = ProtocolModel.attribute(of: proto)
      {
        do {
          interface.protocols.append(try ProtocolModel(proto, attribute: attribute))
        } catch {
          throw IDLError(description: "\(path): protocol \(proto.name.text): \(error)")
        }
      } else if let e = statement.item.as(EnumDeclSyntax.self), let codes = errorCases(e) {
        interface.errors[e.name.text] = ErrorEnum(name: e.name.text, cases: codes)
      }
    }
  }
  return interface
}

/// The cases of an `Int32`-backed enum with literal raw values.
func errorCases(_ e: EnumDeclSyntax) -> [(String, Int32)]? {
  guard let inherited = e.inheritanceClause?.inheritedTypes,
    inherited.contains(where: { $0.type.trimmedDescription == "Int32" })
  else { return nil }
  var cases: [(String, Int32)] = []
  for member in e.memberBlock.members {
    guard let decl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
    for element in decl.elements {
      guard let raw = element.rawValue?.value.as(IntegerLiteralExprSyntax.self),
        let code = Int32(String(raw.literal.text.filter { $0 != "_" }))
      else { return nil }
      cases.append((element.name.text, code))
    }
  }
  return cases
}
