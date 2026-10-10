# Todhchai: directives for work in this repository

Design docs are in `docs/` (start with `README.md`); the current
milestone's steps are in `docs/milestones/`.

## Build

The toolchain is pinned by `.swift-version` (6.4.0, as croi's) and found
through swiftly. There are three builds, and each step keeps them passing:

    swift build && swift test             # hosted: tier 1, tools, tests (SwiftPM)
    cmake --workflow --preset embedded    # tier 0 as Embedded Swift: build + ctest
    .build/debug/td boot --test           # tier 0 on croi in QEMU (see "Native")

Before committing, run everything a change must pass, including the
build-time budgets (docs/performance.md):

    swift build --product td && .build/debug/td ci     # --no-bench to skip the bench
    .build/debug/td bench --record                       # on a clean tree: record a passing run

The reference programs' budgets (M1's exit: minimal, synth, game loop;
and N0's, from `n0-bench`) are `td bench --programs`. It opens windows and plays (muted) audio, so it
runs only on request, from the desktop; their traces stay in
`bench/out/programs/`.

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

## Native (croi)

M3 runs tier 0 on croi (`docs/milestones/M3.md`). `td boot` builds croi's
loader and kernel from `../croi`'s last commit, never its working tree
(exported to `build/croi/src`; no pin: the two become one repository
later) into `build/croi/<arch>`, and our tree with
the `native-<arch>` presets (`cmake/croi.cmake`: croi's triples and user
flags, programs linked by ld.lld at 0x1000000) into `build/native-<arch>`.
It writes a bootfs of every program in `build/native-<arch>/bin`
(`lib/bootfs`, Zircon's format, byte-identical to croi's `mkbootfs.py`),
lays out the ESP in `build/boot/<arch>/esp` with
`userboot.next=bin/launcher`, and runs QEMU (KVM on amd64):

    .build/debug/td boot [--arch amd64|arm64|rv64] [--test] [--next bin/P]
                         [--manifests DIR] [--cmdline WORDS] [-- QEMU ARGS]

`--test` passes when userboot reports the program exited with 0; the
console is in `bench/out/boot/<arch>/console.log`, and a croi build failure
or panic is reported as croi's. `td ci` builds all three arches and boots
amd64. A program is `todhchai_program(name sources)` in `CMakeLists.txt`
(sources in `boot/programs/`), linked with `libsys` (`lib/sys/native`, ours:
`_start` and the syscall instruction in assembly, then processargs, stdout
over debuglog and a heap over VMOs in Swift). Embedded Swift has no
`CommandLine`: use `Arguments.strings`, `Environment` and
`StartupHandles.take`. `bin/launcher` (`boot/programs/launcher`) is
lib/launch natively: programs are bootfs's `bin/NAME`, manifests its
`etc/manifests/*.manifest` (`td boot --manifests DIR` puts them there), and
`--cmdline launcher.until=SERVICE` makes it exit with that service's code.
`Process.start` natively loads the ELF from bootfs (`lib/elf`,
`lib/sys/backend/native/Loader.swift`); a started program finds its
Startup channel as `StartupHandles.take(ProcessArgs.info(ProcessArgs.user0))`.
`td ci` boots the launcher's test (`tests/native/manifests`) and N0's exit
(`bin/n0-exit` with `boot/native`, the native boot's manifests: block over
a ramdisk, fs, catalog). N0's programs are one body each in `lib/services`
(tier 0), which the hosted programs (`lib/hosted`) and the native ones
(`boot/programs/<name>`) wrap. Our libc exports `mem*` and `str*` under their C
names natively only (`lib/libc/native`, never in SwiftPM's build).

## devmgr and drivers

`bin/devmgr` (`boot/programs/devmgr`, M3g, M3h) reads the firmware's
tables from croi's boot data (`lib/zbi`: K9b's ZBI items; the manifest's
`bootdata`), loads ACPI's namespace with its regions over the machine
(`lib/devmgr/Firmware.swift`), maps the MCFG's ECAM window, enumerates PCI
(`lib/pci`, tier 0: `ConfigSpace`, `ECAM`, `enumerate`), binds drivers by
the Swift predicates in `lib/devmgr/Rules.swift` (first match wins) and
runs a driver host per bound device with its own `Launcher`, mounting each
host's tree at `drivers/SERVICE`. A manifest grants hardware with
`resource mmio|irq|ioport|smc|system` (the launcher's ranged roots from
userboot), `programs` (bootfs and a job under the service's) and
`bootdata`. A host
gets exactly its device's resources as `HandleType.device` startup
handles (argument 0-5 a BAR, 0x10 its config space): read them with
`DeviceResources(take: StartupHandles.take)`, and its registers through
`Registers` (volatile). Device registers are read with `_Volatile`, which
needs `-enable-experimental-feature Volatile` on the target. The test is
`td boot --test --manifests tests/native/devices --cmdline
launcher.until=devices-test -- -device edu` (QEMU's edu device and
`bin/edu`), in `td ci`. A0's budgets on croi: `td boot --test --next
bin/acpi-bench --data .cache/acpi/NAME` (`--data DIR` puts files in bootfs
as `data/NAME`), in `td ci` when the corpus is here.

## The console

`bin/console` (`boot/programs/console`, M3j) maps the GOP framebuffer that
croi's boot data names (write-combining) and shows the system log from
croi's debuglog (`resource system` grants reading it; `Debuglog` in Sys),
plus what is written to its `write` leaf; `screen` reads back the grid.
`lib/console` (tier 0) is the text grid and renderer, in the desktop's
colors. Its font is Spleen (third-party data, `data/fonts/spleen`, with
PROVENANCE.md); after changing the data, regenerate and commit:

    .build/debug/fontgen lib/console/generated/Spleen.swift data/fonts/spleen

`tests/console` fails if the committed table doesn't match the data. To
look at the screen, boot without `--test` with `-- -monitor
unix:SOCK,server=on,wait=off` and send `screendump FILE.ppm`.

## IPC protocols

A library is a Swift file with an `@IPCLibrary` enum holding structs,
enums and protocols (architecture §4, `docs/wire-format.md`); the macro
generates each protocol's client, handler, server and events inside it.
After changing one, regenerate its C header (one per library), its
protocols' pages and baselines, and commit them:

    .build/debug/idlc --c-out DIR --doc-out DIR --baseline DIR FILE      # check
    .build/debug/idlc ... --update-baseline FILE                         # record

`idlc` exits 1 if the change would break a client of the recorded
baseline. A protocol composes others by naming them as it would inherit
(`protocol Directory: NodeIPC.Node`, FIDL's `compose`); for another
library's, pass its file to idlc with `--with lib/node/Node.swift`. A
composed client lends its connection for another library's calls:
`dir.node { (c: inout NodeIPC.NodeClient) throws(...) in try c.walk(names) }`.
A public library's structs that other modules build need an explicit
public memberwise `init` (labels as the fields, in order). The test library's outputs live in `tests/ipc/{c/generated,docs,baselines}`.
Calls go through `channel_call` and record FLOW records with croi's flow
ids (category `ipc`).

## Node

`lib/node` is the Node protocol every service serves (architecture §6)
and `NodeTree`, the helper that publishes an in-memory tree with text
leaves (`status`, `ctl`). A service serves all its channels from one
thread with `IPCDispatcher` (lib/ipc/runtime); change the tree from any
thread and watchers hear. A process's `Namespace` (lib/node) maps paths
to unions of Node channels, resolved in the client; `SrvBoard` is the
session's `/srv`. idlc's outputs for Node and the board are in
`lib/node/idl`.

## The launcher

`lib/launch` reads manifests (one directive a line, documented at the top
of `Manifest.swift`), starts a job and a process per service with only
what the manifest grants, and restarts by policy. A program reads its
`Startup` first. The hosted boot runs the manifests in `boot/manifests`
with the programs registered in `lib/hosted/Programs.swift`:

    swift build --product hostboot && .build/debug/hostboot [--check] [DIR]

`boot/manifests` is N0's exit (M3's, hosted): block, fs, and `catalog`, a
client that writes songs with attributes through `/data` and watches a live
query (`tests/milestones/N0ExitTests.swift`). The block image is
`.build/hosted/block.img`.

## The block service

`lib/block` serves a device's blocks through rings in a shared VMO
(`lib/block/ring`, `BlockRing`, tier 0; the layout and wakeup rules are
at the top of `Ring.swift`). A client walks to the service node
`/svc/block/device` (`Namespace.connect`), which speaks `BlockIPC.Device`,
not Node: it opens the ring and attaches buffer VMOs, and the data goes
through the ring. Hosted, `FileBackend` is an image file; the hosted
boot's `block` program makes `.build/hosted/block.img`. idlc's outputs are
in `lib/block/idl`.

## The fs service

`lib/fs` serves a Taisce volume over a block session (`RingDevice`):
`FsIPC.Directory` and `File` compose Node and `Attributes`, so `cat` and
`ls` work through any Node client, and add listings with attributes,
rename, queries, live queries (a channel of their own), indices and sync.
The service's tree is `status` and `volume` (the root; a manifest mounts
it with `mount /data fs/volume`). The hosted boot's `fs` program formats
the block image if it holds no volume. Conveniences: `lib/fs/Client.swift`.

## Sys

`Sys` (`lib/sys`, tier 0) is how services reach the kernel: croi's object
model with Zircon's values (`lib/sys/abi`), handles as `~Copyable`
`Handle`s. SwiftPM builds it over the hosted kernel (`SysHost`,
`lib/sys/host`, with td_kernel.h's C ABI); the native CMake build over
croi's syscalls (`lib/sys/backend/native`, M3b); the host's Embedded
build over a stub that fails every call. Hosted processes are threads in
one Linux process, each with its own handle table; a killed one's threads
exit at their next kernel call. Threads: `Thread.spawn { }` and
`Thread.join`; locks: `Lock` over futexes (`Futex.wait`/`wake`). Tests of
the native backend are programs in `tests/native`, run on croi with
`td boot --test --next bin/<name>` (`bin/sys-test` and
`bin/services-test`, N0's services in one process, are in `td ci`). Errors
come in croi's order: bad handle, wrong type, access denied. Plans:
`docs/milestones/N0.md`, `M3.md`.

## Tracing

`Trace` (lib/trace) records zones, flows, counters and marks in the format
of `docs/trace-format.md`, the same records croi's kernel writes. Record a
program and read the result with:

    .build/debug/td trace record -o DIR [-c app,frame,...] [--circular] -- PROGRAM ARGS
    .build/debug/td trace summary DIR        # also: print, diff A B

On croi, `TraceSession` (lib/trace/session) records the kernel's rings and
a region per process (given in processargs); the files come out over the
debuglog and `td boot` puts them in `bench/out/boot/<arch>/trace`, which
`td trace summary` also reads as one timeline (calls through croi). N0's
run: `td boot --test --next bin/n0-exit --manifests boot/native --cmdline
n0.trace=ipc,app,mark`. The console carries ~110 KB/s: keep recordings
small.

## Wayland

The hosted SDK speaks Wayland directly (architecture §18). The protocol
XML is data in `data/wayland` (see its PROVENANCE.md). After changing it,
regenerate and commit the output:

    .build/debug/wlgen lib/wayland/generated/Protocols.swift data/wayland/{wayland,xdg-shell,presentation-time,viewporter,fractional-scale-v1,linux-dmabuf-v1,linux-drm-syncobj-v1}.xml

Tests that open real windows run only with `TODHCHAI_LIVE_WINDOWS=1`;
`td ci` doesn't set it, so ordinary runs never put windows on the desktop.

## Vulkan

The host's Vulkan loader is used through bindings we generate: `vkgen`
reads `data/vulkan/vk.xml` (with its PROVENANCE.md) and writes a C header,
so struct layouts are C's, plus a Swift command table. The selection
(core 1.0–1.4 and the extensions Loinnir needs) is in
`lib/vulkan/gen/Selection.swift`. After changing either, regenerate and
commit:

    .build/debug/vkgen lib/vulkan/c/include/td_vulkan.h lib/vulkan/swift/generated/Commands.swift data/vulkan/vk.xml

A test checks every struct's size and field offsets against Khronos's
header where the host has it.

## Taisce

The file system ([docs/filesystem.md](docs/filesystem.md); stage plan in
`docs/milestones/S0.md`). `lib/taisce` is tier 0, in both builds;
`lib/taisce-host` holds the host's devices and tools. On-disk structures
are byte arrays with explicit little-endian fields (`Bytes.swift`), never
memory layouts. Every change to what reaches the disk goes through a
`BlockDevice`, so `RecordingDevice` can replay any prefix of the writes as
a crash. Since S1, every node is copy-on-write with a BLAKE3-128 checksum
in its parent pointer, and a group commits by superblock flip (no log):
never write a committed block in place.

On the host: `swift build --product mkfs.taisce` (also `fsck.taisce`,
`taisce-fuse`), then

    .build/debug/mkfs.taisce -s 1G IMAGE
    .build/debug/taisce-fuse IMAGE MOUNTPOINT      # Ctrl-C unmounts
    .build/debug/fsck.taisce IMAGE

Queries through the mount: `echo 'size > 1MiB' > MOUNTPOINT/.taisce/query;
cat MOUNTPOINT/.taisce/query` (`live` streams changes; `index` declares).
Typed attributes are `user.` xattrs, e.g. `setfattr -n user.Audio:Year -v
int64:1993 FILE`. If a test leaves a dead mount, `fusermount3 -u -z
MOUNTPOINT` clears it. The S0 and S1 exit tests mount for real and run
only with `TODHCHAI_LIVE_FUSE=1`; Taisce's budgets are in `td bench
--programs` (S1's `fsync` and commit ones use an image under `.build`, so
the host's disk).

## ACPI

`TDACPI` (`lib/acpi`, tier 0) reads firmware tables and is our AML
interpreter, from ACPI 6.5 with no ACPICA (milestone A0,
`docs/milestones/A0.md`). Real tables are kept out of the tree, in
`.cache/acpi`:

    sudo .build/debug/td acpi import     # this machine's tables, and Linux's device view
    .build/debug/td acpi fetch-qemu      # QEMU's, at a pinned release
    .build/debug/td acpi list

Tests over the corpus skip when it's absent; synthetic AML comes from the
tests' own encoder (`tests/acpi/AML.swift`). The fuzzer runs 40 mutants a
table in `td ci`; `TODHCHAI_ACPI_FUZZ=N swift test --filter mutatedTables`
runs more, and a crash's seed is the last `fuzz` line on stderr. A0's
budgets (`acpi-bench`) are in `td bench --programs`.

## Crypto

`TDCrypto` (`lib/crypto`, tier 0) is our cryptography, from published
specifications (architecture §17). So far: BLAKE3, which Taisce checksums
blocks with (first 128 bits). Test vectors are data with provenance
(`data/blake3`); `tests/crypto` runs all of them.

## Unicode

`TDUnicode` (`lib/unicode`, tier 0) gives NFC and NFD (UAX #15), full case
folding and strict UTF-8, from tables generated out of the UCD files in
`data/unicode` (see its PROVENANCE.md). After changing the data, regenerate
and commit:

    .build/debug/ucdgen data/unicode lib/unicode/generated/Tables.swift

`tests/unicode` runs all of NormalizationTest.txt, and fails if the
committed tables don't match the data.

## Shaders

Shaders are GLSL (`.vert`, `.frag`, `.comp`) compiled with glslang to a
`.spv` beside each source, and the `.spv` is committed. After editing a
shader, run `.build/debug/td shaders`; `td ci` fails on stale SPIR-V.
Loinnir shaders read their inputs through the root pointer
(`GL_EXT_buffer_reference`, a push constant) and textures from the heap
(set 0: binding 0 `texture2D[]`, binding 1 a sampler). Don't name a GLSL
variable `texture`: it hides the `texture()` function.

## The C ABI

`libtodhchai.so` (`swift build --product todhchai`) is the SDK's C ABI
(sdk.md §12). The ABI is described in `lib/capi/gen/Todhchai.swift`, and
`abigen` writes the C header and the Zig and Odin bindings from it, with
layout assertions in each. After changing the description or
`KeyUsage.swift`, regenerate and commit:

    .build/debug/abigen lib/sdk/KeyUsage.swift lib/capi/c/include/todhchai/todhchai.h lib/capi/zig/todhchai.zig lib/capi/odin/todhchai/todhchai.odin

`lib/capi/swift/CABI.swift` implements it with `@c`. Tests call through
the C declarations (`import TDCABI`), not the Swift functions, which
would be ambiguous. The minimal program is in `examples/minimal` in C,
Zig and Odin. Odin is `/opt/odin/odin` on this machine.

## Audio

The hosted SDK plays through PipeWire's native protocol, spoken directly
(`lib/pipewire`, spec in `docs/research/pipewire-protocol.md`). Renderers
are `@AudioRenderer` types: the compiler rejects allocation, locks and
calls it can't see into inside `render`, so compute tables outside it.
Live audio tests run only with `TODHCHAI_LIVE_AUDIO=1` (they play
silence); `.build/debug/tone` plays something you can hear. Render
threads get real-time scheduling from RealtimeKit over our own D-Bus
(`lib/sdk/DBus.swift`) when the account has no RLIMIT_RTPRIO; check
`AudioStream.admission` before trusting an underrun count.

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
- **`Set` and `Dictionary` in tier 0 code need libm.** Embedded Swift's
  hashed collections size their storage with `ceil`, and tier 0 links
  without libm, so the Embedded link fails with `undefined reference to
  'ceil'`. Use arrays (flags, sorted arrays) in tier 0 code. Found in S0a.
- **No key paths in tier 0 code.** Embedded Swift rejects them
  (`EmbeddedRestrictions`), including `\.name` passed as a function to
  `map` or `first(where:)`; write a closure (`{ $0.name }`). The hosted
  build accepts them, so only the Embedded build catches it.
- **Signal handlers can't be closures in `main.swift`'s top-level code.**
  Top-level code is main-actor-isolated, so the handler's isolation check
  traps when the signal lands on another thread. Put the handler in a
  library, as a plain function that only sets an atomic. Found in S0h.
- **Don't ignore SIGCHLD before spawning a helper.** The ignore is
  inherited across exec, and breaks the helper's own `waitpid`
  (`fusermount3: waitpid: No child processes`). Found in S0h.
- **Outside the repository, swiftly picks its default toolchain**, not
  `.swift-version`'s: a scratch experiment gets 6.3.1, which crashes
  compiling Embedded atomics. Call 6.4.0's `swiftc` by its path there.
- **Send test signals to the process** (`kill(getpid(), sig)`), not the
  thread: the test runner's worker threads block signals.
- **rv64 native code is `lp64`, not croi's `lp64d`.** The toolchain's
  prebuilt rv64 Embedded libraries (the Unicode tables) are soft-float ABI,
  and ld.lld won't link the two; we reach croi only through syscalls.
- **Tier 0 code has no `weak` or `unowned`** (Embedded Swift rejects
  them) and no Synchronization `Mutex` on croi's targets: use `Sys.Lock`
  or `Sys.Locked`, and break reference cycles where their owner ends (a
  session's server holds a token whose deinit marks it closed).
- **The CMake builds load the IPC macro from SwiftPM's build**
  (`.build/debug/IPCMacros`): run `swift build` before configuring them.
- **Embedded Swift's String has no `contains(String)`** (Foundation's):
  compare bytes or whole lines (`utf8.elementsEqual`, `utf8.starts(with:)`).
- **A large allocation natively is a mapping** (libsys's heap: past 128
  KiB, a VMO, page faults and an unmap with a TLB shootdown): keep them out
  of hot paths. A channel message is read sized (M3e).
- **A CMake option for Swift must be guarded in a target with assembly**
  (`$<$<COMPILE_LANGUAGE:Swift>:...>`), or clang gets it.

## Layout

- `lib/`    libraries, by component (`lib/ipc/wire/` is `IPCWire`, tier 0).
- `tools/`  host tools (`idlc`, `td`).
- `boot/`   what boots: the hosted boot's manifests, and the native
            programs (`boot/programs/`).
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
  emits it. Source generated from third-party data keeps the data's
  license and notice (`lib/console/generated/Spleen.swift` is
  BSD-2-Clause, Spleen's).
- When you edit a source file that lacks the identifier, add it.
- Third-party data (fonts, standards tables, community databases) keeps its
  own license and is never relabelled. It lives apart from source with its
  provenance recorded (principle 29, roadmap "Decided").
- Don't add a per-file copyright notice; [LICENSE](LICENSE) holds it.
