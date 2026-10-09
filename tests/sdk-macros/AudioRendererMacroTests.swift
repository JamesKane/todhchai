// SPDX-License-Identifier: BSD-3-Clause

// @AudioRenderer's expansion: @_noAllocation on `render` (so the compiler
// rejects allocation, locks and reference counting in it) and the
// conformance with its marker.

import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing
import TodhchaiMacros

let specs: [String: MacroSpec] = ["AudioRenderer": MacroSpec(type: AudioRendererMacro.self, conformances: ["AudioRenderer"])]

@Test func renderIsCheckedAndTheTypeConforms() {
  assertMacroExpansion(
    """
    @AudioRenderer
    struct Synth {
      var phase: Float = 0
      mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {}
      func helper() {}
    }
    """,
    expandedSource: """
      struct Synth {
        var phase: Float = 0
        @_noAllocation
        mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {}
        func helper() {}
      }

      extension Synth: AudioRenderer {
        public static var _realtimeChecked: AudioRealtimeChecked {
          .byTheCompiler
        }
      }
      """,
    macroSpecs: specs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message)) })
}

@Test func aTypeWithoutRenderIsRefused() {
  assertMacroExpansion(
    "@AudioRenderer\nstruct Nothing {}",
    expandedSource: "struct Nothing {}",
    diagnostics: [DiagnosticSpec(message: "@AudioRenderer needs a `render(into:time:)` method", line: 1, column: 1)],
    macroSpecs: specs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message)) })
}
