// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Hosted build: tier 1 code, tools and every test that runs on Linux. Tier 0
// libraries are built here too (as ordinary Swift, for their tests), and
// again by CMake as Embedded Swift (CMakeLists.txt), which proves they are
// Embedded-clean.

import PackageDescription

// The flags tier 0 code is held to everywhere (croi's, cmake/embedded.cmake).
let tier0: [SwiftSetting] = [
  .enableExperimentalFeature("Lifetimes"),
  .strictMemorySafety(),
  .unsafeFlags(["-Werror", "StrictMemorySafety"]),
]

let package = Package(
  name: "todhchai",
  targets: [
    .target(name: "IPCWire", path: "lib/ipc/wire", swiftSettings: tier0),
    .testTarget(name: "IPCWireTests", dependencies: ["IPCWire"], path: "tests/ipc/wire",
                swiftSettings: tier0),
  ]
)
