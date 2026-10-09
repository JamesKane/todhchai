# Todhchai

*Todhchaí* is Irish for "future".

Todhchai is a desktop operating system written in Swift, built on top of
[croi](../croi), a Zircon-style microkernel written in Embedded Swift. Its aim
is to be the OS the Handmade crowd keeps asking for:
- the app owns its loop, its memory and its timing;
- the layers are thin and you can see through them;
- the file system answers queries the way BeOS's did;
- the desktop is built on Vulkan with a retro-future cyberpunk look and never
  makes a game wait for its effects.

Status: **design.** No code yet. To resume, start with
[docs/next-steps.md](docs/next-steps.md). croi boots on amd64, arm64 and rv64 and is
working toward user space.

## Goals
1. The whole stack in Swift: Embedded Swift for system services, full Swift
   for apps and kits. A C ABI makes C, Zig, Odin, Rust and Jai full
   citizens.
2. Minimal abstraction layers, except where they make the SDK pleasant.
   Hackers can draw a window, read input and play a sound in about 12 calls,
   and the same core scales to AAA engines.
3. A modern desktop on Vulkan, inspired by BeOS (Tracker, Deskbar, yellow
   tabs, replicants, queries everywhere) with a retro-future cyberpunk look.
4. Taisce, a modern Be-style file system: typed attributes, indices, live queries
   and a persistent change journal first; copy-on-write, checksums and
   snapshots after.
5. The lessons of the NeoDarwin API study (`../NeoDarwin-api-study`): 30
   friction points with proposed fixes, the converged API shapes, and
   heritage lessons.
6. Everything is ours. New libraries are written in Swift, falling back to
   another language only when Swift can't do the job fast enough.
   Foundations such as libc, text, crypto, compression and the GPU drivers
   are written clean-room from specifications or reverse engineering. The
   tree contains no third-party code. The only exception is development
   toolchains (Swift, clang, LLVM).
7. The Handmade circle's asks: the app owns its loop, arenas with
   reserve/commit, debugging and hot reload as OS services, single-file apps,
   measured latency, and visibility into what the system is doing.

## Documents
| Doc | Contents |
|---|---|
| [docs/principles.md](docs/principles.md) | 29 design principles, each tied to its source; §I (Swift first, no third-party code) overrides the rest |
| [docs/architecture.md](docs/architecture.md) | Layers, Swift tiers, process tree, IPC, namespaces (bind, union, sealed), the Node protocol, memory, scheduling and power, drivers, graphics, storage, audio, input, packaging, compatibility, observability, security and keyring, hosted mode, remote export bridge, and the foundations we write with their specifications |
| [docs/sdk.md](docs/sdk.md) | SDK modules, loop and events, minimal programs in Swift and C, the Loinnir GPU library, audio, UI Kit, Game Kit, C ABI rules, tools, reference programs |
| [docs/desktop.md](docs/desktop.md) | Radharc, the compositor (nestable, plane-first, late latch, game mode), window management, shell apps and scripting, the router, replicants and translators, theme tokens and rendering budget |
| [docs/filesystem.md](docs/filesystem.md) | Taisce, the file system: staged features, on-disk layout, storage engine, snapshots as directories, attributes, query language v2, live queries, trade-offs |
| [docs/performance.md](docs/performance.md) | Performance budgets with the milestone that enforces each, how they are measured from traces, what the profiling tools must show, and what happens when a budget is violated |
| [docs/wire-format.md](docs/wire-format.md) | The IPC wire format: header, message kinds, ordinals, cancellation, epitaphs, body layout |
| [docs/croi-requirements.md](docs/croi-requirements.md) | What the kernel must provide, in order, and the extensions a low-latency game desktop needs |
| [docs/roadmap.md](docs/roadmap.md) | Four work tracks, milestones M0–M10 with exit tests, risks, open and decided questions |
| [docs/next-steps.md](docs/next-steps.md) | Where the design stopped, how to re-sync with croi, which milestone to start, and what to re-verify |
| [docs/research/](docs/research/) | Source research: NeoDarwin digest, croi assessment, Handmade discussions, BeFS/BeOS/compositor/Swift systems research, 9front desktop and system studies (rio, devdraw, plumber, acme, /proc, gefs, factotum, namespaces, exportfs, 9P), and the hardware targets (the amd64 reference machine and the two arm64 boards, from AbyssBSD's bring-up) |

The research notes tag each claim: `[V]` verified against a cited source,
`[S]` secondary source, `[K]`/`[U]` background knowledge or unverified.
Check a `[U]` claim before you rely on it.

## License

Todhchai, the OS and the SDK, is licensed under the
[BSD 3-Clause License](LICENSE). Every source file starts with
`SPDX-License-Identifier: BSD-3-Clause` in its language's comment syntax
([CLAUDE.md](CLAUDE.md)).
