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
open, never silently. On this machine the bench is advisory: other agents
and QEMU sessions make timings noisy, so `td ci` reports budgets without
failing on them, and `--record` refuses while the machine is busy. Only a
quiet, dedicated build server runs `--enforce`.

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

## Tracing

`Trace` (lib/trace) records zones, flows, counters and marks in the format
of `docs/trace-format.md`, the same records croi's kernel writes. Record a
program and read the result with:

    .build/debug/td trace record -o DIR [-c app,frame,...] [--circular] -- PROGRAM ARGS
    .build/debug/td trace summary DIR        # also: print, diff A B

## Wayland

The hosted SDK speaks Wayland directly (architecture §18). The protocol
XML is data in `data/wayland` (see its PROVENANCE.md). After changing it,
regenerate and commit the output:

    .build/debug/wlgen lib/wayland/generated/Protocols.swift data/wayland/{wayland,xdg-shell,presentation-time,viewporter,fractional-scale-v1}.xml

Tests that open real windows run only with `TODHCHAI_LIVE_WINDOWS=1`;
`td ci` doesn't set it, so ordinary runs never put windows on the desktop.

## Audio

The hosted SDK plays through PipeWire's native protocol, spoken directly
(`lib/pipewire`, spec in `docs/research/pipewire-protocol.md`). Renderers
are `@AudioRenderer` types: the compiler rejects allocation, locks and
calls it can't see into inside `render`, so compute tables outside it.
Live audio tests run only with `TODHCHAI_LIVE_AUDIO=1` (they play
silence); `.build/debug/tone` plays something you can hear.

## libc (the F track)

`lib/libc` is our libc, in Swift, written from ISO C and POSIX
(principle 29). `lib/libc/symbols.tsv` lists what the toolchain's runtime
needs (`td libc-symbols` regenerates it). Every function gets a
differential test in `tests/libc` against the host's glibc: seeded random
cases, comparing results and whole buffers.

## Toolchain pitfalls

- **Swift 6.4 miscompiles a `throws(E)` closure passed to a `rethrows`
  function** (such as `Array.withUnsafeMutableBytes`) when the caller then
  casts the caught error (`error as? E`). The error comes out corrupt: wrong
  values and garbage type metadata, and printing it crashes. Pass an
  untyped closure there. Found in M0c; a minimal reproduction is
  `tests/toolchain/TypedThrowsRethrows.swift`.

- **Swift's Glibc module lacks Linux's own interfaces** (epoll, eventfd,
  timerfd) and the GNU extensions (prctl, sched_setattr,
  pthread_setname_np), and Swift can't call variadic C (syscall). They
  come through the `TDLinux` shim (`lib/sdk/linux`).
- **Swift Testing's `#expect` and `#require` can't take an expression on a
  `~Copyable` value** (an `Arena`, a `Handle`): compute into a local first.
- **Send test signals to the process** (`kill(getpid(), sig)`), not the
  thread: the test runner's worker threads block signals.

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
