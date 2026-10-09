# Roadmap

Work runs on four tracks, so user space never waits for the kernel:

- **K: croi kernel**, in `../croi`. Its order is set by
  [croi-requirements.md](croi-requirements.md).
- **H: hosted.** The SDK, compositor, UI Kit and file system run on Linux and
  are measured against the reference programs ([architecture.md](architecture.md)
  §18).
- **N: native.** Todhchai user space on croi, replacing hosted backends one at
  a time.
- **F: foundations.** The clean-room libraries principle 29 makes ours.
  Each one is developed and tested hosted on Linux (where it can be checked
  against the host's equivalent) long before native code needs it:
  - libc and the dynamic linker;
  - text (shaper, rasterizer, Unicode algorithms);
  - compression;
  - crypto and TLS;
  - image and audio codecs;
  - the AML interpreter;
  - the SPIR-V front end and shader compiler back ends.

  See [architecture.md](architecture.md) §20.

Milestones are ordered by dependency, not dated. Each one has an exit test
that can be checked.

## Milestones

### M0: Groundwork
- Repository layout, build (CMake/Ninja like croi for tier 0, SwiftPM for
  hosted tools), CI that runs the hosted reference programs and records
  clean and incremental build time per component.
- `td bench` and the budget report: each budget's number and history per
  machine, a failing run's trace kept ([performance.md](performance.md)).
  Build times are the first budgets it judges.
- The F track starts: its differential test harness against the host's
  libraries, and the first foundation (libc, written against the symbol
  lists the Swift runtime and FoundationEssentials need).
- A prototype of the `@IPCProtocol` macro and `idlc` (Swift and C output,
  evolution check), over an in-process transport.
- **Exit:** a protocol defined once has a Swift client, a C client and a Swift
  server, and they exchange a message carrying a handle, in a test.

### M1: Hosted SDK core (H)
- `Loop`, `Window`, `Frame`, `Input`, `Audio`, `Memory`/`Arena` and `Thread`
  on Linux. The backend is a Wayland client; DRM/KMS fullscreen comes later
  for latency work.
- The C ABI and generated headers. Zig and Odin bindings work.
- Prism v0 on Linux Vulkan 1.4.
- Reference programs: minimal, synth, game loop.
- The SDK's `Trace` module and the hosted tracer, writing the record format
  croi uses, so the programs' numbers below are read from traces.
- **Exit:** minimal ≤ 13 calls; 0 idle wakeups; synth has 0 underruns at 128
  frames with a compiler-checked callback; game loop has p99 frame error
  ≤ 1 ms against present feedback (needs `VK_EXT_present_timing` or
  `wp_presentation`).

### M2: croi reaches user space (K)
- croi requirements items 1–12: handoff v2, IRQs, clock, PMM, heap, threads,
  PI, the deadline scheduler, SMP, VMM phase A, handles, syscalls, vDSO, user
  SIMD, channel/port/futex/timer, process/job, userboot, and the core of
  item 18 (kernel trace and sampling).
- **Exit:** userboot starts a tier 0 Embedded Swift process from bootfs. It
  creates a channel pair, passes a VMO across, waits on a port with a
  deadline timer, and prints over debuglog, on all three arches in QEMU.
  The kernel and IPC budgets ([performance.md](performance.md) §2) are
  measured from croi's trace and met under KVM.

### M3: Native tier 0 (N)
- `libsys` (the Embedded Swift runtime shims), the native IPC transport with
  transaction cancel, the launcher with manifests and namespaces (bind,
  union, sealed), and the Node protocol with its SDK helper, so every
  service has a `/svc/<name>/` tree from its first day.
- The native tracer: flows in the generated IPC code and the ring library,
  sampling with symbols, the flight recorder, and `td trace` (text,
  summaries, comparing two traces). Every later milestone's budgets are
  measured with it.
- devmgr and driver hosts; our AML interpreter; PCI/ECAM; virtio blk, net,
  input, gpu-2d and sound; the GOP framebuffer.
- The block service and **BeFS-NG S0**, which have been developed hosted in
  parallel: FUSE plus a crash harness on Linux.
- **Exit:** boot to a framebuffer text console in QEMU. Mount a BeFS-NG S0
  volume on virtio-blk, write files with attributes, and get a live query
  update for them. M3's system budgets (boot to console, spawn to `main`,
  a cached read, a live query, resident memory) are met in QEMU.

### M4: Native desktop v0 (N)
- Compositor on the framebuffer with CPU composition. Input service with the
  HID class and keymaps. Audio service on virtio-sound and then HDA.
- The SDK's native backend for `Loop`, `Window`, `CPUSurface`, `Input` and
  `Audio`.
- The display-timeline object and admission control ([croi-requirements.md](croi-requirements.md) §3, items 1 and 4).
- **Exit:** the M1 minimal and synth programs, unchanged, run natively and
  meet their M1 numbers in QEMU (audio within virtualization limits). The
  compositor runs nested inside itself, two levels deep.

### M5: Vulkan (N)
- Our libc (F track): pthreads over futexes, ELF TLS, the dynamic linker.
- Our Vulkan loader. A virtio-gpu 3D system driver plus our **Venus**
  client driver (Magma-shaped split), generated from `vk.xml` and the Venus
  protocol XML.
- Buffer negotiation, the GPU buffer object, counters as timeline semaphores.
- Compositor on Vulkan (async compute, late latch), and Prism native.
- **Exit:** the game-loop reference program runs on Venus under QEMU. A
  fullscreen app is presented by direct scanout of the virtio-gpu scanout
  buffer.

### M6: Full Swift and the shell (N)
- The toolchain's full Swift stdlib and runtime, built for a Todhchai target
  on our libc, plus FoundationEssentials, with a native `TaskExecutor`.
- Text stack (F track): shaper, rasterizer, MSDF, segmentation, bidi.
  Translators for PNG, JPEG and FLAC. The SDK has read WAV itself since M1.
- The UI Kit with the default Neon Tab theme and the accessibility tree.
- Tracker (attributes, queries), Deskbar (replicants), Terminal (termbench),
  Inspector, Preferences.
- The router (plumber) with rules, the keyring with the shell's trusted
  confirmation prompt, and app scripting (properties, intent streams,
  claim and decline).
- **Exit:** a usable desktop session in QEMU. The text-editor, terminal and
  file-browser reference programs meet their criteria.

### M7: Games and tools (N)
- Game Kit, `CodeModule` hot reload, record and replay.
- `debugd` (start suspended, post-mortem attach) and `td debug`, the
  tracer's timeline viewer and GPU track (over M3's tracer),
  `td build`/`td bundle`.
- The export bridge: remote debugging, tracing and file access from a dev
  box to a test machine.
- Our own games and demos on Game Kit and Prism, which exercise the SDK the
  way third parties will.
- **Third-party ports, outside the tree:** help SDL upstream land a Todhchai
  backend, and help a Quake-class engine and a few indie games build with
  `td build`. Dawn/wgpu and Zink are welcome as ports run by others.
- **Exit:** a game written on Game Kit and Prism runs with hot reload,
  swapping a 10K-line module in under 1 s. The tracer shows input-to-photon
  latency for a frame. At least one third-party SDL3 game runs through SDL's
  own backend.

### M8: Bare metal (N + K)
- The reference machine: an i7-12700KF with a Radeon RX 6750 XT (RDNA 2),
  the box AbyssBSD runs on. VT-d, NVMe, xHCI with USB HID and audio, HDA,
  and the motherboard's NIC.
- Power on the reference machine: croi's deadline-aware idle over `_CST`,
  capacity-aware placement over the P- and E-cores, and the power service
  with CPPC/HWP frequency policy, ACPI thermal (critical shutdown tested)
  and power profiles ([architecture.md](architecture.md) §8).
- GPU, with the F track's shader compiler as a prerequisite:
  1. our AMD client driver (SPIR-V to RDNA compiler, command encoding) over
     virtio-gpu native context in a VM, checked against the host's driver
     image by image;
  2. our bare-metal AMD system driver (rings, GPU virtual memory, firmware
     loading, display engine).

  Both are written from AMD's published ISA and register documentation, with
  reverse engineering where the documentation stops.
- Game mode: direct scanout, tearing, VRR, overlay planes, HDR.
- **Exit:** boot to the desktop on the reference machine and run the M7 games
  with direct scanout and VRR. Input-to-photon latency is measured and
  published. With the `balanced` profile, frame-pacing misses are no worse
  than with deep idle off, and the idle desktop's wakeups per second are
  published alongside.

### M9: Maturity
- BeFS-NG S1 (CoW and checksums), then S2 (snapshots, compression,
  encryption, send/receive). Atomic system updates.
- Wayland core+ server (ours, from the protocol XML). Intel GPU (from the
  PRMs). The indexer with translators. Media Kit node graphs.
- Later still: NVIDIA (largely reverse engineered). Wine with DXVK and
  vkd3d-proton is for those projects to port. arm64 hardware is M10.

### M10: arm64 boards (N + K)
Starts once M8 works on the reference machine. The boards and what they
need are in [research/hardware-targets.md](research/hardware-targets.md).
- **Measure first.** The M1 hosted reference programs on each board's
  stock Linux (both have working GPU drivers there), so frame pacing and
  idle-wake latency on arm64 are known before native work starts.
- **Orange Pi 6 Plus (CIX Sky1) first:**
  - croi: the DBG2 console, GICv3/ITS (erratum 2941627 checked), the CIX
    timer as the deep-idle wake timer, `_LPI` with SVE state, SMMUv3 with
    RMRs, the SMC resource;
  - the SCMI service, CPPC, ACPI thermal, the SBSA watchdog;
  - NVMe, xHCI and HDA as ACPI platform devices; USB CDC-NCM for the
    network until there is an RTL8126 driver;
  - display tier 1 on the GOP framebuffer, then tier 2 if the Linlon
    pipeline UEFI leaves can be taken over;
  - optionally, Todhchai as a KVM guest on the board with Venus over the
    host's Vulkan, if the host's panvk meets Prism's floor.
- **Radxa Dragon Q8B second:** the GENI console, the MMIO wake timer, EPSS,
  TSENS, the MMU-500s within the hypervisor's rules, starting the ADSP
  (the fan), display tier 2 (the `msmfb` design). Audio, USB-C and the
  TC956x NICs come last: each sits behind Qualcomm firmware protocols or an
  undocumented chip.
- **arm64 GPUs** (Mali CSF, then Adreno) are reverse-engineering projects
  with their own compiler back ends, after the AMD driver is mature. They
  are not part of M10's exit.
- **Exit:** the M6 desktop session on each board with CPU composition: the
  minimal and synth programs meet their M1 numbers, a missed flip is never
  caused by deep idle, the critical-temperature shutdown is tested, and
  the published hardware list names each board with its trusted
  (IOMMU-less) devices.

## Dependency sketch

```
M0 ─┬─► M1 (H) ───────────────────► M4 (SDK native backend)
    └─► M2 (K) ─► M3 ─► M4 ─► M5 ─► M6 ─► M7 ─► M8 ─┬─► M9
                                                    └─► M10 (arm64 boards)

Feeding in from the hosted and F tracks:
    BeFS-NG S0 (H) ─► M3      libc + ld (F) ─► M5
    text stack (F) ─► M6      shader compiler (F) ─► M8
```

## Biggest risks

| Risk | Why | Mitigation |
|---|---|---|
| **GPU drivers** | Principle 29 rules out Mesa, so every GPU driver, including the SPIR-V compiler for each GPU family, is ours. The shader compiler and the display engine are each multi-year efforts. This is the kind of hardware gap that sank BeOS | Venus (no compiler needed) gives real Vulkan in a VM early, so everything above the driver is real years before bare metal. Native context then separates compiler bugs from system-driver bugs. One GPU vendor (AMD, best documented) for a long time. Start the shader compiler on the F track early, checked against the Vulkan CTS and the host's driver |
| **Clean-room workload** | libc, text shaping, crypto, compression, codecs, the AML interpreter and the Wayland server all become ours (architecture §20). Crypto and text shaping are where subtle bugs live | The F track runs from M0, hosted, with differential testing against the host's libraries, the published test vectors and conformance suites, and an external crypto review before TLS ships |
| **Full Swift port** | about 160 libc symbols for the runtime plus what FoundationEssentials needs, on our own libc; no prebuilt toolchain target | Tier 0 needs none of it. The hosted track proves the SDK. Our libc is written against the actual symbol lists of the runtime and FoundationEssentials first, then grown toward POSIX |
| **File system maturity** | Copy-on-write file systems take more than 5 years | Stage it (S0 is useful by itself), crash harness and query fuzzer from day one |
| **Embedded Swift limits** | No library evolution; code size from specialization; concurrency runtime not prebuilt for croi triples | Stable boundary is IPC + C, never Swift ABI; keep tier 0 modules small; build the embedded concurrency runtime ourselves if needed |
| **Scope** | A full desktop OS, with no third-party code to lean on | Hosted track, the F track, standard device classes, a short hardware list, and third parties porting their own software (SDL, WebGPU, Wine) onto our platform interfaces |
| **arm64 boards** | No public ISA for either GPU; the Q8B's firmware routes power through Windows-only PEP and its peripherals through Qualcomm DSP protocols; a wrong register access resets either SoC with no dump | They follow working amd64 code. The Sky1 (SystemReady-style, SCMI) goes first. CPU composition and the display takeover tier carry the desktop without a GPU driver. AbyssBSD's notes record each hazard, so none is found twice |
| **Real-time in Swift** | The `@_noLocks` checker has gaps (libm, class metadata, `&&`) | C trampoline for real-time callbacks; CI counts retains and locks |

## Open decisions

These need the project owner's call. Each one has a recommendation, and
none blocks M0.

1. **SDK GPU API:** Prism, a "No Graphics API"-style library over Vulkan 1.4
   (*recommended*), or `webgpu.h` as the NeoDarwin study chose. See
   [sdk.md](sdk.md) §5.
2. ~~Desktop architecture priority~~: decided (see "Decided").
3. ~~Reference hardware~~: decided (see "Decided").
4. **App format:** an ELF with an appended archive plus attributes
   (*recommended*, single file) or a directory bundle.
5. **Debug info format:** our own fast format, designed from what RDI shows
   works and converted from DWARF at link time (*recommended to evaluate*),
   or DWARF plus our own index.
6. **Hosted backend:** a Wayland client first (*recommended*, easier) or
   DRM/KMS first (better latency measurements).
7. **Component names.** Working names are descriptive ("compositor",
   "BeFS-NG", "Prism"). Irish names would match croi and Todhchai.
8. **License**, for the OS and for the SDK, which may differ (for example
   MIT or Apache-2.0 for the SDK so game engines can use it freely).
9. **Hosted mode as a product.** Keep hosted mode a development tool
   (*recommended until M6*), or ship it Inferno-style on Linux, macOS and
   Windows so developers can target Todhchai early. See
   [architecture.md](architecture.md) §18. Revisit once the native desktop
   is usable and the host backend's cost is known.

## Decided

- **Desktop architecture priority** (2026-10-09): amd64 first. The kernel
  stays tri-arch, and the arm64 boards follow once the amd64 code works
  (M10).
- **Reference hardware** (2026-10-09): an i7-12700KF with a Radeon RX 6750
  XT, plus QEMU `q35` and `virt`. Then the Orange Pi 6 Plus and the Radxa
  Dragon Q8B, the boards AbyssBSD brought up
  ([research/hardware-targets.md](research/hardware-targets.md)).
- **libc:** our own, clean-room from ISO C and POSIX (principle 29).
- **GPU firmware:** part of the hardware. The user installs it from the
  vendor's files, and it is never in our tree.
- **Third-party data:** data is data, not code. Fonts, standards tables and
  community databases are used under their licenses, kept apart from
  source, with their provenance recorded.
- **Clean-room strictness:** "study designs, never copy code" for Todhchai.
  croi follows its own directives.
- **Foundation:** FoundationEssentials, the core of swift-foundation, is
  treated as toolchain for tier 1. The internationalization and networking
  modules are not used.
