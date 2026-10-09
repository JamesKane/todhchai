# Todhchai: directives for work in this repository

Design docs are in `docs/` (start with `README.md`); the current
milestone's steps are in `docs/milestones/`.

## Build

The toolchain is pinned by `.swift-version` (6.4.0, as croi's) and found
through swiftly. There are two builds, and each step keeps both passing:

    swift build && swift test             # hosted: tier 1, tools, tests (SwiftPM)
    cmake --workflow --preset embedded    # tier 0 as Embedded Swift: build + ctest

Before committing, run everything a change must pass, including the
build-time budgets (docs/performance.md):

    swift build --product td && .build/debug/td ci     # --no-bench to skip the bench
    .build/debug/td bench --record                       # on a clean tree: record a passing run

Run td's binary, not `swift run td`: the builds it starts would wait on
SwiftPM's lock. Logs and the budget report go to `bench/out/`; each
machine's recorded history is `bench/history/<host>.tsv`. A regressed
budget is fixed, or recorded with `--accept` as a decision made in the
open, never silently.

- **Hosted (SwiftPM, `Package.swift`).** Everything builds here, tier 0
  libraries included, with croi's strict-memory-safety flags.
- **Embedded (CMake/Ninja, `build/embedded/`).** Tier 0 libraries are built
  again as Embedded Swift for x86_64 Linux with croi's flags
  (`cmake/embedded.cmake`), which proves them Embedded-clean, and their
  test programs in `tests/embedded/` run on the host. A tier 0 library
  is listed in both `Package.swift` and `CMakeLists.txt`.

## IPC protocols

A protocol is a Swift file with an `@IPCProtocol` protocol (architecture §4,
`docs/wire-format.md`). After changing one, regenerate its C header, page
and baseline, and commit them:

    swift run idlc --c-out DIR --doc-out DIR --baseline DIR FILE      # check
    swift run idlc ... --update-baseline FILE                         # record

`idlc` exits 1 if the change would break a client of the recorded
baseline. The test protocol's outputs live in `tests/ipc/{c/generated,docs,baselines}`.

## Toolchain pitfalls

- **Swift 6.4 miscompiles a `throws(E)` closure passed to a `rethrows`
  function** (such as `Array.withUnsafeMutableBytes`) when the caller then
  casts the caught error (`error as? E`). The error comes out corrupt: wrong
  values and garbage type metadata, and printing it crashes. Pass an
  untyped closure there. Found in M0c; a minimal reproduction is
  `tests/toolchain/TypedThrowsRethrows.swift`.

## Layout

- `lib/`    libraries, by component (`lib/ipc/wire/` is `IPCWire`, tier 0).
- `tools/`  host tools (`idlc`, `td`).
- `tests/`  Swift Testing suites by component; `tests/embedded/` holds the
            Embedded test programs.
- `cmake/`  the Embedded toolchain settings.

## License and SPDX identifiers

Todhchai is licensed under BSD-3-Clause ([LICENSE](LICENSE)), the OS and
the SDK alike.

Every source file starts with an SPDX identifier when it is created:

| Files | First line |
|---|---|
| Swift, C, C++, headers, Zig, Odin, assembly (`.S`), linker scripts, GLSL/HLSL | `// SPDX-License-Identifier: BSD-3-Clause` |
| Shell, Python, CMake, YAML, TOML, Makefiles | `# SPDX-License-Identifier: BSD-3-Clause` |
| Files with a shebang | the shebang, then the identifier on the second line |

- Generated source (`idlc` output, headers generated for the C ABI, tables
  generated from specifications) carries the identifier too: the generator
  emits it.
- When you edit a source file that lacks the identifier, add it.
- Third-party data (fonts, standards tables, community databases) keeps its
  own license and is never relabelled. It lives apart from source with its
  provenance recorded (principle 29, roadmap "Decided").
- Don't add a per-file copyright notice; [LICENSE](LICENSE) holds it.
