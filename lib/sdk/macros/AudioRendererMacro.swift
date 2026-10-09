// SPDX-License-Identifier: BSD-3-Clause

// @AudioRenderer (sdk.md §7): makes a type an audio renderer whose
// `render` method the compiler checks for allocation and locks
// (@_noAllocation, which also rules out locks and reference counting). A
// real-time callback that allocates or locks fails to build, not to play.

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main struct TodhchaiMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [AudioRendererMacro.self]
}

struct MacroError: Error, CustomStringConvertible {
  let description: String
}

public struct AudioRendererMacro: MemberAttributeMacro, ExtensionMacro {
  /// `@_noAllocation` on the type's `render` methods.
  public static func expansion(
    of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol, in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard let function = member.as(FunctionDeclSyntax.self), function.name.text == "render" else { return [] }
    return ["@_noAllocation"]
  }

  /// The conformance, and the marker only this macro writes.
  public static func expansion(
    of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let hasRender = declaration.memberBlock.members.contains {
      $0.decl.as(FunctionDeclSyntax.self)?.name.text == "render"
    }
    guard hasRender else { throw MacroError(description: "@AudioRenderer needs a `render(into:time:)` method") }
    let decl: DeclSyntax = """
      extension \(type.trimmed): AudioRenderer {
        public static var _realtimeChecked: AudioRealtimeChecked { .byTheCompiler }
      }
      """
    return [decl.cast(ExtensionDeclSyntax.self)]
  }
}
