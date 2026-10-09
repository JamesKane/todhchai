// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Hosted build: tier 1 code, tools and every test that runs on Linux. Tier 0
// libraries are built here too (as ordinary Swift, for their tests), and
// again by CMake as Embedded Swift (CMakeLists.txt), which proves they are
// Embedded-clean.

import CompilerPluginSupport
import PackageDescription

// The flags tier 0 code is held to everywhere (croi's, cmake/embedded.cmake).
let tier0: [SwiftSetting] = [
  .enableExperimentalFeature("Lifetimes"),
  .strictMemorySafety(),
  .unsafeFlags(["-Werror", "StrictMemorySafety"]),
]

let package = Package(
  name: "todhchai",
  dependencies: [
    // Toolchain, not third-party code (principle 29): the release matching
    // the Swift 6.4 compiler, for the @IPCProtocol macro and idlc.
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
  ],
  targets: [
    .target(name: "IPCWire", path: "lib/ipc/wire", swiftSettings: tier0),
    .testTarget(name: "IPCWireTests", dependencies: ["IPCWire"], path: "tests/ipc/wire",
                swiftSettings: tier0),

    // The hosted kernel: croi's handles, channels, events and waits, in one
    // Linux process, with a C ABI (td_kernel.h).
    .target(name: "TDKernel", path: "lib/ipc/host/c"),
    .target(name: "IPCHost", dependencies: ["TDKernel"], path: "lib/ipc/host", exclude: ["c"]),
    .target(name: "IPCHostCTests", dependencies: ["TDKernel"], path: "tests/ipc/host/c"),
    .testTarget(name: "IPCHostTests", dependencies: ["IPCHost", "IPCHostCTests"],
                path: "tests/ipc/host", exclude: ["c"]),

    // @IPCProtocol: the macro, and the runtime its generated code calls.
    .target(name: "IPCModel", dependencies: [
      "IPCWire", .product(name: "SwiftSyntax", package: "swift-syntax"),
      .product(name: "SwiftParser", package: "swift-syntax"),
    ], path: "lib/ipc/model"),
    .macro(name: "IPCMacros", dependencies: [
      "IPCModel",
      .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    ], path: "lib/ipc/macros"),
    // idlc: C headers, docs and API baselines from the same protocol files.
    .target(name: "IDL", dependencies: [
      "IPCModel", .product(name: "SwiftParser", package: "swift-syntax"),
    ], path: "lib/ipc/idl"),
    .executableTarget(name: "idlc", dependencies: ["IDL"], path: "tools/idlc"),
    .target(name: "IDLCTests", dependencies: ["TDWire"], path: "tests/ipc/c", exclude: ["generated"],
            cSettings: [.headerSearchPath("generated")]),
    .testTarget(name: "IDLTests", dependencies: ["IDL", "IDLCTests", "IPC"], path: "tests/ipc/idl",
                swiftSettings: [.enableExperimentalFeature("Lifetimes")]),

    // The F track's libc (architecture §20), tier 0, tested against the host's.
    .target(name: "LibC", path: "lib/libc", exclude: ["symbols.tsv"], swiftSettings: tier0),
    .testTarget(name: "LibCTests", dependencies: ["LibC"], path: "tests/libc"),

    // The trace format, the SDK's Trace module (the writer) and the reader
    // (docs/trace-format.md).
    .target(name: "TraceFormat", path: "lib/trace/format"),
    .target(name: "TDTraceCPU", path: "lib/trace/c"),
    .target(name: "Trace", dependencies: ["TraceFormat", "TDTraceCPU"], path: "lib/trace/writer"),
    .target(name: "TraceReader", dependencies: ["TraceFormat"], path: "lib/trace/reader"),
    .testTarget(name: "TraceTests", dependencies: ["Trace", "TraceReader"], path: "tests/trace"),
    .executableTarget(name: "trace-cost", dependencies: ["Trace"], path: "tools/trace-cost"),

    // Wayland, spoken directly (architecture §18): wlgen turns the protocol
    // XML in data/wayland into lib/wayland/generated; Wayland is the runtime.
    .target(name: "WaylandGen", path: "lib/wayland/gen"),
    .executableTarget(name: "wlgen", dependencies: ["WaylandGen"], path: "tools/wlgen"),
    .target(name: "Wayland", path: "lib/wayland", exclude: ["gen"], sources: ["runtime", "generated"]),
    .testTarget(name: "WaylandTests", dependencies: ["Wayland", "WaylandGen"], path: "tests/wayland"),

    // The SDK (sdk.md): the Swift overlay of libtodhchai, hosted on Linux.
    .target(name: "TDLinux", path: "lib/sdk/linux"),
    .target(name: "Todhchai", dependencies: ["Trace", "TDLinux", "Wayland"], path: "lib/sdk", exclude: ["linux"]),
    .testTarget(name: "TodhchaiTests", dependencies: ["Todhchai", "Wayland"], path: "tests/sdk"),

    // td: the developer tool (bench, ci); Bench is its testable core.
    .target(name: "Bench", path: "lib/bench"),
    .executableTarget(name: "td", dependencies: ["Bench", "TraceFormat", "TraceReader"], path: "tools/td"),
    .testTarget(name: "BenchTests", dependencies: ["Bench"], path: "tests/bench"),

    // Each milestone's exit test (docs/milestones/).
    .testTarget(name: "MilestoneTests", dependencies: ["Echo", "IDLCTests"], path: "tests/milestones",
                swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
    // td_wire.h: the wire format in C, for idlc's headers.
    .target(name: "TDWire", dependencies: ["TDKernel"], path: "lib/ipc/c"),
    .target(name: "IPC", dependencies: ["IPCWire", "IPCHost", "IPCMacros"], path: "lib/ipc/runtime",
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
    .testTarget(name: "IPCMacrosTests", dependencies: [
      "IPCMacros",
      .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
    ], path: "tests/ipc/macros"),
    // The test protocol and its server, shared by the tests below.
    .target(name: "Echo", dependencies: ["IPC"], path: "tests/ipc/echo",
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
    .testTarget(name: "IPCTests", dependencies: ["IPC", "Echo"], path: "tests/ipc/runtime",
                swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  ]
)
