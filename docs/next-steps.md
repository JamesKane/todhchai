# Next steps

Where the design stopped on 2026-10-09, and how to pick it up again once croi
is further along.

## Where things stand

- **Design is done to the level of architecture and roadmap.** No code
  exists yet. The docs agree with each other, and the research behind them
  is in [research/](research/).
- **Decided:**
  - principles 28 and 29 (Swift first; no third-party code, foundations
    written clean-room);
  - firmware is hardware; data is data;
  - "study designs, never copy code";
  - FoundationEssentials counts as toolchain;
  - our own libc; LLVM's libc++ for the Swift runtime, as toolchain;
  - Loinnir as the SDK's GPU API; the single-file ELF app format; our own
    debug-info format converted from DWARF; a Wayland client as the first
    hosted backend; hosted mode as a development tool only;
  - amd64 first, on the reference machine (i7-12700KF, RX 6750 XT); the
    Orange Pi 6 Plus and Radxa Dragon Q8B follow once that works.

  See [roadmap.md](roadmap.md), "Decided".
- **Reviewed against the arm64 boards** (2026-10-09), from AbyssBSD's
  bring-up notes: [research/hardware-targets.md](research/hardware-targets.md).
  That review added power management (architecture §8), display as its own
  driver with three tiers (§10), the board database and SCMI (§9), DMA
  exceptions (§17), new croi requirements (items 1–3, 5, 7, 13, 14; §3 items
  11–12; §4), and milestone M10.
- **Still open:** no decisions in [roadmap.md](roadmap.md). The last,
  the C++ runtime under the full Swift runtime, was decided after M0h:
  LLVM's libc++ as toolchain.
- **Re-synced with croi on 2026-10-10** (at K8b, M2 nearly closed):
  [research/croi-assessment-2026-10-10.md](research/croi-assessment-2026-10-10.md)
  and the status table in [croi-requirements.md](croi-requirements.md).
  The paragraph below is the 2026-10-09 state.
- **croi at the time of writing:** it boots on amd64, arm64 and rv64,
  builds its own page tables, installs exception vectors and halts. It has
  no PMM, threads, user mode, syscalls or kernel objects yet
  ([research/croi-assessment.md](research/croi-assessment.md)). Later the
  same day croi added the PMM, the kernel heap and address space, SMP,
  handoff v3 (bootfs, command line, framebuffer, cache policy) and
  interrupt controllers with IPIs (`b2eb02e`), so the re-sync below has
  real work to check. One thing already known: croi's loader finds no
  console on either arm64 board (no SPCR on the Sky1, a GENI UART on the
  Q8B).

## When resuming: re-sync with croi first

1. **Read croi's current state:** `../croi/CLAUDE.md` and
   `git -C ../croi log --oneline`.
2. **Tick off [croi-requirements.md](croi-requirements.md).** For items
   1–12 (the path to the first user process) and 13–19, record which exist,
   which are partial and which differ from what Todhchai assumed. Pay
   particular attention to:
   - **handoff v2** (bootfs, framebuffer, command line);
   - the **syscall ABI and vDSO** shape;
   - **user FP/SIMD state**;
   - the **scheduler's deadline profiles** and priority inheritance;
   - the **IOMMU** work (VT-d, AMD-Vi).
3. **Check the extensions in croi-requirements §3** (display timeline, IPC
   deadline donation, overrun notices, admission with a reason, IRQ-to-thread,
   GPU memory accounting, JIT views, CPU isolation, topology page). Did any of
   them land? Were any designed differently? Update the doc to match croi,
   not the other way round.
4. **Refresh the assessment.** Update
   [research/croi-assessment.md](research/croi-assessment.md), or add a dated
   follow-up next to it, so the roadmap's estimates rest on current facts.

## Which milestone to start

- **If croi has reached M2** (userboot runs a tier 0 process that uses
  channels, VMOs, ports and timers), start **M3**: `libsys`, the native IPC
  transport, the launcher and namespaces, the Node protocol, devmgr with the
  AML interpreter, virtio drivers, and the block service plus Taisce S0.
- **If not, start where croi isn't needed.** These run fully hosted on
  Linux:
  - **M0:**
    - set up the repo layout and build (CMake/Ninja for tier 0, SwiftPM for
      hosted tools);
    - CI with build-time tracking;
    - prototype the `@IPCProtocol` macro and `idlc`. The exit test: one
      protocol, with a Swift client, a C client and a Swift server,
      exchanging a message that carries a handle.
  - **M1:** the hosted SDK core (`Loop`, `Window`, `Frame`, `Input`,
    `Audio`, `Memory`, `Thread`) as a Wayland client, plus the C ABI, Loinnir
    v0 and the minimal, synth and game-loop reference programs.
  - **F track:** the libc test harness, then libc written against the Swift
    runtime's and FoundationEssentials' symbol lists.
  - **Taisce S0**, hosted through `/dev/fuse` with the crash harness and
    the fuzzers.

## Decisions to make before the milestone that needs them

None are left; every open decision has been made (roadmap, "Decided").

## Facts to re-verify, since they may have moved

- **Swift toolchain:** the version croi pins (`../croi/.swift-version`, 6.4.0
  in October 2026). Check what Embedded Swift now supports: existentials,
  untyped `throws`, concurrency, whether `libswift_Concurrency` is prebuilt
  for croi's triples, and the `@c` / `@implementation` naming limits croi's
  CLAUDE.md records.
- **Swift runtime symbol lists:** the about-160 libc symbols that
  `libswiftCore` needs, and what FoundationEssentials adds. Re-run `llvm-nm
  -u` against the current toolchain before writing libc.
- **Vulkan:** the status of `VK_EXT_present_timing`, descriptor heaps and
  unified image layouts (Loinnir's hardware floor), and whether the Venus
  protocol XML has moved.
- **Unverified claims in the research notes** (tagged `[U]`). In particular,
  the NoGraphicsAPI library's date and license, Mesa/Magma details, and the
  Handmade attributions listed in research/handmade.md Part 5.

## Housekeeping

- The repo has no remote yet. Pick one before collaborating.
- **A build server.** The development machine runs several agents and QEMU
  sessions at once, so its timings are noisy and `td bench` is advisory
  there. A quiet, dedicated machine running `td ci --enforce` (and
  recording the baselines) is what makes the budgets binding
  (performance.md §5). Set it up before M1's exit budgets have to hold.
- A `CLAUDE.md` for this repo (conventions, build commands, the ownership
  rules) is worth writing once there is code to build.
