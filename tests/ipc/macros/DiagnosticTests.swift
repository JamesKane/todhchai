// SPDX-License-Identifier: BSD-3-Clause

// What @IPCProtocol refuses, and the message it gives.

import IPCMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

let specs: [String: MacroSpec] = [
  "IPCProtocol": MacroSpec(type: IPCProtocolMacro.self),
  "oneway": MacroSpec(type: MarkerMacro.self),
  "event": MacroSpec(type: MarkerMacro.self),
  "since": MacroSpec(type: MarkerMacro.self),
]

/// Expands `body` inside an @IPCProtocol protocol and expects one error.
func expectRefusal(_ body: String, _ message: String, header: String = #"id: "t.P", version: 1"#,
                   sourceLocation: SourceLocation = #_sourceLocation) {
  let source = "@IPCProtocol(\(header))\nprotocol P {\n\(body)\n}"
  // The marker attributes are macros too, and expand to nothing.
  let markers = #/@(oneway|event|since\(\d+\)) /#
  let expanded = "protocol P {\n\(body.replacing(markers, with: ""))\n}"
  assertMacroExpansion(
    source, expandedSource: expanded,
    diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
    macroSpecs: specs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message), sourceLocation: sourceLocation) })
}

@Test func refusesUnsupportedTypes() {
  expectRefusal("func f(_ x: Int)", "'f': parameter type 'Int' is not supported yet")
  expectRefusal("func f() -> [String]", "'f': result type '[String]' is not supported yet")
}

@Test func refusesUntypedThrowsAndAsync() {
  expectRefusal("func f() throws", "'f': a throwing method declares its error type: throws(E)")
  expectRefusal("func f() async", "'f': IPC methods are not async")
}

@Test func refusesBadMarkers() {
  expectRefusal("@since(3) func f()", "'f': @since needs a version from 1 to 1")
  expectRefusal("@oneway func f() -> UInt8", "'f': a one-way method or event has no result and doesn't throw")
  expectRefusal("@event func f(_ h: Handle)", "'f': events can't carry handles yet")
}

@Test func refusesBadArguments() {
  expectRefusal("func f()", "@IPCProtocol needs id: a string literal", header: #"id: "", version: 1"#)
  expectRefusal("func f()", "@IPCProtocol needs version: an integer ≥ 1", header: #"id: "t.P", version: 0"#)
  expectRefusal("var x: Int { get }", "an IPC protocol holds only methods")
}
