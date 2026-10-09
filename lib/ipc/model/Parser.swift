// SPDX-License-Identifier: BSD-3-Clause

// Reads an @IPCProtocol protocol declaration into the model. The macro and
// idlc both use this, so they can't disagree about a protocol.

import SwiftParser
import SwiftSyntax

/// A protocol the model can't accept, and why.
public struct ModelError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// A protocol declared with @IPCProtocol.
public struct ProtocolModel {
  public var name: String
  public var id: String
  public var version: Int
  public var isPublic: Bool
  public var methods: [Method]

  /// Reads `proto`, whose @IPCProtocol attribute is `attribute`.
  public init(_ proto: ProtocolDeclSyntax, attribute: AttributeSyntax) throws(ModelError) {
    do {
      let (id, version) = try Self.arguments(attribute)
      self.id = id
      self.version = version
      methods = try proto.memberBlock.members.map { member throws -> Method in
        guard let function = member.decl.as(FunctionDeclSyntax.self) else {
          throw ModelError("an IPC protocol holds only methods")
        }
        return try Self.parseMethod(function, protocolID: id, version: version)
      }
    } catch let error as ModelError {
      throw error
    } catch {
      throw ModelError("\(error)")
    }
    name = proto.name.text
    isPublic = proto.modifiers.contains { $0.name.text == "public" }
    var seen: [UInt64: String] = [:]
    for method in methods {
      if let other = seen[method.ordinal] {
        throw ModelError("methods '\(other)' and '\(method.name)' have the same ordinal; rename one")
      }
      seen[method.ordinal] = method.name
    }
  }

  /// The @IPCProtocol attribute of a protocol, if it has one.
  public static func attribute(of proto: ProtocolDeclSyntax) -> AttributeSyntax? {
    for attribute in proto.attributes {
      if let a = attribute.as(AttributeSyntax.self), a.attributeName.trimmedDescription == "IPCProtocol" {
        return a
      }
    }
    return nil
  }

  static func arguments(_ node: AttributeSyntax) throws -> (String, Int) {
    var id: String?
    var version: Int?
    for argument in node.arguments?.as(LabeledExprListSyntax.self) ?? [] {
      switch argument.label?.text {
      case "id":
        id = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
      case "version":
        version = argument.expression.as(IntegerLiteralExprSyntax.self).flatMap { Int($0.literal.text) }
      default: break
      }
    }
    guard let id, !id.isEmpty else { throw ModelError("@IPCProtocol needs id: a string literal") }
    guard let version, version >= 1 else { throw ModelError("@IPCProtocol needs version: an integer ≥ 1") }
    return (id, version)
  }

  static func parseMethod(_ f: FunctionDeclSyntax, protocolID: String, version: Int) throws -> Method {
    let name = f.name.text
    var kind = MethodKind.call
    var since = 1
    for attribute in f.attributes {
      guard let a = attribute.as(AttributeSyntax.self) else { continue }
      switch a.attributeName.trimmedDescription {
      case "oneway": kind = .oneway
      case "event": kind = .event
      case "since":
        guard let n = a.arguments?.as(LabeledExprListSyntax.self)?.first?.expression
          .as(IntegerLiteralExprSyntax.self).flatMap({ Int($0.literal.text) }), n >= 1, n <= version
        else { throw ModelError("'\(name)': @since needs a version from 1 to \(version)") }
        since = n
      default: break
      }
    }

    var parameters: [Parameter] = []
    for p in f.signature.parameterClause.parameters {
      var typeSyntax = p.type
      if let attributed = typeSyntax.as(AttributedTypeSyntax.self) { typeSyntax = attributed.baseType }
      let swiftType = typeSyntax.trimmedDescription
      guard let type = WireType(swiftType: swiftType) else {
        throw ModelError("'\(name)': parameter type '\(swiftType)' is not supported yet")
      }
      let internalName = (p.secondName ?? p.firstName).text
      let label = p.firstName.text == "_" ? nil : p.firstName.text
      parameters.append(Parameter(label: label, name: internalName, swiftType: swiftType, type: type))
    }

    var result: (String, WireType)?
    if let r = f.signature.returnClause?.type.trimmedDescription, r != "Void", r != "()" {
      guard let type = WireType(swiftType: r) else {
        throw ModelError("'\(name)': result type '\(r)' is not supported yet")
      }
      result = (r, type)
    }

    var errorType: String?
    if let effects = f.signature.effectSpecifiers {
      if effects.asyncSpecifier != nil { throw ModelError("'\(name)': IPC methods are not async") }
      if let clause = effects.throwsClause {
        guard let t = clause.type?.trimmedDescription else {
          throw ModelError("'\(name)': a throwing method declares its error type: throws(E)")
        }
        if t != "Never" { errorType = t }
      }
    }

    switch kind {
    case .call: break
    case .oneway, .event:
      if result != nil || errorType != nil {
        throw ModelError("'\(name)': a one-way method or event has no result and doesn't throw")
      }
      if kind == .event, parameters.contains(where: { $0.type == .handle }) {
        throw ModelError("'\(name)': events can't carry handles yet")
      }
    }

    return Method(
      name: name, kind: kind, since: since, parameters: parameters, result: result,
      errorType: errorType, ordinal: ordinal(protocolID: protocolID, method: name))
  }
}
