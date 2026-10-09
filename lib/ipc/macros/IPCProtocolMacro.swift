// SPDX-License-Identifier: BSD-3-Clause

// @IPCProtocol: reads a protocol declaration and generates its client,
// handler, server and event types (architecture §4, docs/wire-format.md).

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main struct IPCMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [IPCProtocolMacro.self, MarkerMacro.self]
}

/// `@oneway`, `@event` and `@since(n)`: read by `@IPCProtocol`; they
/// generate nothing themselves.
public struct MarkerMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] { [] }
}

struct MacroError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

public struct IPCProtocolMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
      throw MacroError("@IPCProtocol applies to a protocol")
    }
    let (id, version) = try arguments(node)
    let methods = try proto.memberBlock.members.compactMap { member -> Method? in
      guard let function = member.decl.as(FunctionDeclSyntax.self) else {
        throw MacroError("an IPC protocol holds only methods")
      }
      return try parseMethod(function, protocolID: id, version: version)
    }
    var seen: [UInt64: String] = [:]
    for method in methods {
      if let other = seen[method.ordinal] {
        throw MacroError("methods '\(other)' and '\(method.name)' have the same ordinal; rename one")
      }
      seen[method.ordinal] = method.name
    }
    let name = proto.name.text
    let access = proto.modifiers.contains { $0.name.text == "public" } ? "public " : ""
    return Generator(name: name, access: access, methods: methods).declarations()
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
    guard let id, !id.isEmpty else { throw MacroError("@IPCProtocol needs id: a string literal") }
    guard let version, version >= 1 else { throw MacroError("@IPCProtocol needs version: an integer ≥ 1") }
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
        else { throw MacroError("'\(name)': @since needs a version from 1 to \(version)") }
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
        throw MacroError("'\(name)': parameter type '\(swiftType)' is not supported yet")
      }
      let internalName = (p.secondName ?? p.firstName).text
      let label = p.firstName.text == "_" ? nil : p.firstName.text
      parameters.append(Parameter(label: label, name: internalName, swiftType: swiftType, type: type))
    }

    var result: (String, WireType)?
    if let r = f.signature.returnClause?.type.trimmedDescription, r != "Void", r != "()" {
      guard let type = WireType(swiftType: r) else {
        throw MacroError("'\(name)': result type '\(r)' is not supported yet")
      }
      result = (r, type)
    }

    var errorType: String?
    if let effects = f.signature.effectSpecifiers {
      if effects.asyncSpecifier != nil { throw MacroError("'\(name)': IPC methods are not async") }
      if let clause = effects.throwsClause {
        guard let t = clause.type?.trimmedDescription else {
          throw MacroError("'\(name)': a throwing method declares its error type: throws(E)")
        }
        if t != "Never" { errorType = t }
      }
    }

    switch kind {
    case .call: break
    case .oneway, .event:
      if result != nil || errorType != nil {
        throw MacroError("'\(name)': a one-way method or event has no result and doesn't throw")
      }
      if kind == .event, parameters.contains(where: { $0.type == .handle }) {
        throw MacroError("'\(name)': events can't carry handles yet")
      }
    }

    return Method(
      name: name, kind: kind, since: since, parameters: parameters, result: result,
      errorType: errorType, ordinal: ordinal(protocolID: protocolID, method: name))
  }
}
