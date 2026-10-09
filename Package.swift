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
  products: [
    // libtodhchai.so: the C ABI (sdk.md §12), for C, Zig, Odin and the rest.
    .library(name: "todhchai", type: .dynamic, targets: ["TodhchaiCABI"]),
    // Taisce on the host (filesystem.md §9).
    .executable(name: "mkfs.taisce", targets: ["MkfsTaisce"]),
    .executable(name: "fsck.taisce", targets: ["FsckTaisce"]),
    .executable(name: "taisce-fuse", targets: ["TaisceFuse"]),
    .executable(name: "taisce-bench", targets: ["TaisceBench"]),
  ],
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
    .target(name: "XMLReader", path: "lib/xml"),
    .target(name: "WaylandGen", dependencies: ["XMLReader"], path: "lib/wayland/gen"),
    .executableTarget(name: "wlgen", dependencies: ["WaylandGen"], path: "tools/wlgen"),
    .target(name: "Wayland", path: "lib/wayland", exclude: ["gen"], sources: ["runtime", "generated"]),
    .testTarget(name: "WaylandTests", dependencies: ["Wayland", "WaylandGen", "XMLReader"], path: "tests/wayland"),

    // Vulkan: vkgen turns data/vulkan/vk.xml into a C header; Vulkan is
    // the loader over the host's libvulkan.so.1.
    .target(name: "VulkanGen", dependencies: ["XMLReader"], path: "lib/vulkan/gen"),
    .executableTarget(name: "vkgen", dependencies: ["VulkanGen"], path: "tools/vkgen"),
    .target(name: "TDVulkan", path: "lib/vulkan/c"),
    .target(name: "Vulkan", dependencies: ["TDVulkan"], path: "lib/vulkan/swift"),
    .testTarget(name: "VulkanTests", dependencies: ["Vulkan", "VulkanGen"], path: "tests/vulkan"),
    // libtodhchai's C ABI (sdk.md §12): the description and abigen, which
    // writes the C header and Zig and Odin bindings from it.
    .target(name: "ABIGen", path: "lib/capi/gen"),
    .executableTarget(name: "abigen", dependencies: ["ABIGen"], path: "tools/abigen"),
    .target(name: "TDCABI", path: "lib/capi/c"),
    .target(name: "TodhchaiCABI", dependencies: ["Todhchai", "TDCABI"], path: "lib/capi/swift"),
    .testTarget(name: "CABITests", dependencies: ["ABIGen", "TodhchaiCABI", "TDCABI"], path: "tests/capi",
                exclude: ["c"]),
    // Cryptography, ours (architecture §17): BLAKE3 for now, tier 0.
    // Optimized even in debug builds: every Taisce block is hashed, and an
    // unoptimized BLAKE3 made the file system's tests several times slower.
    .target(name: "TDCrypto", path: "lib/crypto", swiftSettings: tier0 + [.unsafeFlags(["-O"])]),
    .testTarget(name: "CryptoTests", dependencies: ["TDCrypto"], path: "tests/crypto"),
    // Unicode (filesystem.md §6; the text stack later): NFC and case
    // folding from the UCD (data/unicode), tier 0.
    .target(name: "TDUnicode", path: "lib/unicode", swiftSettings: tier0),
    .target(name: "UCDGen", path: "lib/unicode-gen"),
    .executableTarget(name: "ucdgen", dependencies: ["UCDGen"], path: "tools/ucdgen"),
    .testTarget(name: "UnicodeTests", dependencies: ["TDUnicode", "UCDGen"], path: "tests/unicode"),
    // Taisce (filesystem.md): the file system's core is tier 0, built
    // again as Embedded Swift by CMake; the host's devices and tools are not.
    .target(name: "Taisce", dependencies: ["TDUnicode", "TDCrypto"], path: "lib/taisce", swiftSettings: tier0),
    .target(name: "TaisceHost", dependencies: ["Taisce", "TDLinux"], path: "lib/taisce-host"),
    .executableTarget(name: "MkfsTaisce", dependencies: ["Taisce", "TaisceHost"], path: "tools/mkfs-taisce"),
    .executableTarget(name: "FsckTaisce", dependencies: ["Taisce", "TaisceHost"], path: "tools/fsck-taisce"),
    .executableTarget(name: "TaisceFuse", dependencies: ["Taisce", "TaisceHost"], path: "tools/taisce-fuse"),
    .executableTarget(name: "TaisceBench", dependencies: ["Taisce", "Trace"], path: "tools/taisce-bench"),
    .testTarget(name: "TaisceTests", dependencies: ["Taisce", "TaisceHost"], path: "tests/taisce"),
    .target(name: "FuseLayoutC", path: "tests/taisce-host/c"),
    .testTarget(name: "TaisceHostTests", dependencies: ["Taisce", "TaisceHost", "FuseLayoutC"], path: "tests/taisce-host",
                exclude: ["c"]),
    // Loinnir: the SDK's GPU library (sdk.md §5), on Vulkan.
    .target(name: "Loinnir", dependencies: ["Vulkan", "Todhchai"], path: "lib/loinnir"),
    .testTarget(name: "LoinnirTests", dependencies: ["Loinnir"], path: "tests/loinnir", exclude: ["shaders"]),

    // PipeWire, spoken directly (docs/research/pipewire-protocol.md).
    .target(name: "PipeWire", dependencies: ["TDLinux"], path: "lib/pipewire"),
    .testTarget(name: "PipeWireTests", dependencies: ["PipeWire"], path: "tests/pipewire"),

    // The SDK (sdk.md): the Swift overlay of libtodhchai, hosted on Linux.
    .target(name: "TDLinux", path: "lib/sdk/linux"),
    .macro(name: "TodhchaiMacros", dependencies: [
      .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    ], path: "lib/sdk/macros"),
    .target(name: "Todhchai", dependencies: ["Trace", "TDLinux", "Wayland", "PipeWire", "TodhchaiMacros"], path: "lib/sdk",
            exclude: ["linux", "macros"]),
    .testTarget(name: "TodhchaiTests", dependencies: ["Todhchai", "Wayland", "TDLinux"], path: "tests/sdk"),
    .testTarget(name: "TodhchaiMacrosTests", dependencies: [
      "TodhchaiMacros",
      .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
    ], path: "tests/sdk-macros"),

    // Examples you can run to see, or hear, a piece working.
    .executableTarget(name: "tone", dependencies: ["Todhchai"], path: "examples/tone"),
    // The reference programs (M1h): their budgets are td bench --programs.
    .executableTarget(name: "minimal", dependencies: ["Todhchai", "Trace"], path: "examples/minimal",
                      exclude: ["minimal.c", "minimal.zig", "minimal.odin", "beep.wav", "make-beep.py"]),
    .executableTarget(name: "synth", dependencies: ["Todhchai", "Trace"], path: "examples/synth"),
    .executableTarget(name: "gameloop", dependencies: ["Loinnir", "Todhchai", "Trace"], path: "examples/gameloop",
                      exclude: ["shaders"]),

    // td: the developer tool (bench, ci); Bench is its testable core.
    .target(name: "Bench", dependencies: ["TraceFormat", "TraceReader"], path: "lib/bench"),
    .executableTarget(name: "td", dependencies: ["Bench", "TraceFormat", "TraceReader", "ABIGen"], path: "tools/td"),
    .testTarget(name: "BenchTests", dependencies: ["Bench", "TraceFormat", "TraceReader"], path: "tests/bench"),

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
