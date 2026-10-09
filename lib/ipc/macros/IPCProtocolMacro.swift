// SPDX-License-Identifier: BSD-3-Clause

// @IPCProtocol: reads a protocol declaration and generates its client,
// handler, server and event types (architecture §4, docs/wire-format.md).

import IPCModel
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

public struct IPCProtocolMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
      throw ModelError("@IPCProtocol applies to a protocol")
    }
    let model = try ProtocolModel(proto, attribute: node)
    return Generator(name: model.name, access: model.isPublic ? "public " : "", methods: model.methods)
      .declarations()
  }
}
