# Architecture

Todhchai is the user space that runs on croi (`../croi`), a Zircon-style
microkernel written in Embedded Swift. croi provides handles, virtual memory
objects, channels, ports, threads and a deadline scheduler. Everything else
runs as separate processes in user space: drivers, the file system, the
compositor, audio, the shell and apps. Those processes talk over channels and
shared memory.

This document is the map. The design docs cover the parts in detail:
[sdk.md](sdk.md), [desktop.md](desktop.md), [filesystem.md](filesystem.md),
[croi-requirements.md](croi-requirements.md). The rules all of them follow are
in [principles.md](principles.md), and the order of work is in
[roadmap.md](roadmap.md).

## 1. Layers

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Apps & games          Swift / C / Zig / Odin / Rust / Jai / C++ engines  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ Kits (Swift, optional)  UI Kit (immediate) · Media Kit · Storage Kit     │
 │                         Game Kit (polled state, SDL-shaped callbacks)    │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ Core SDK  libtodhchai   Loop · Window · Frame · Input · Audio · Memory · │
 │ (C ABI, Swift overlay)  Thread · File/Query · Node · Route · Auth ·      │
 │                         Debug · Trace                                    │
 ├────────────────────────────────┬─────────────────────────────────────────┤
 │ Vulkan (our client driver,     │ libc (ours, from ISO C + POSIX)         │
 │ in-process) + GPU lib "Loinnir"│ (ports and the full Swift runtime only) │
 ├────────────────────────────────┴─────────────────────────────────────────┤
 │ System services (separate processes, mostly Embedded Swift)              │
 │  launcher · devmgr + driver hosts · gpu system driver · display · power  │
 │  compositor · input · audio · fs (Taisce) · block · net · indexer        │
 │  tracer · keyring · router (plumber) · debugd · export bridge            │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ IPC protocols (Swift-source IDL → Swift + C bindings) over channels,     │
 │ plus shared-memory rings with notification handles                       │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ vDSO: the only syscall entry; time without a syscall                     │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ croi kernel: handles · VMO/VMAR · channel · port · futex · timer ·       │
 │ deadline scheduler · interrupts · BTI/IOMMU · display timeline · counter │
 └──────────────────────────────────────────────────────────────────────────┘
```

Each layer depends only on the layers below it, with no cycles, in the RAD
Debugger style. Any layer can be used without the ones above it. A game can link
`libtodhchai` and Vulkan and never touch a Kit.

## 2. Languages and runtimes

There are two Swift tiers and one C boundary.

| Tier | Used for | Swift mode | Runtime needs |
|---|---|---|---|
| **0: system** | userboot, launcher, devmgr, drivers, fs, the real-time paths of the compositor, audio and input | Embedded Swift, with croi's flags (strict memory safety, typed throws, `~Copyable`, `Span`, no existentials on hot paths) | about 6 libc symbols (`posix_memalign`, `free`, `memset`, `putchar`, `arc4random_buf`, stack guard). `libsys` provides them over VMAR and cprng syscalls. |
| **1: apps and tools** | the shell, system apps, Kits, apps that want existentials, `Codable` or `async` | Full Swift (the toolchain's stdlib, runtime and concurrency runtime) plus FoundationEssentials. No internationalization or networking Foundation modules: the Kits provide those | Todhchai libc (clean-room from ISO C and POSIX) with pthreads over futexes, ELF TLS, our dynamic linker, and a native `TaskExecutor` over ports instead of libdispatch |
| **C ABI** | `libtodhchai.so`, plus generated headers for C, Zig, Odin, Rust and Jai | Implemented in Swift with `@c` and `@implementation` | Nothing beyond tier 0, so a C game never pulls in the full Swift runtime |

Rules, the first carried over from croi's conventions:
- Strict memory safety is an error everywhere. Every unsafe use is marked
  `unsafe`. Types that wrap raw pointers are `@safe`, with `@unsafe`
  initializers that state their contract.
- Real-time code (audio callbacks, compositor latch, input dispatch) has to
  compile under `@_noLocks` and `@_noAllocation`. A violation fails the build.
  The NeoDarwin S7 synth showed this works, with gaps: no libm, no first use of
  a class, no `&&` or `||` inside checked code. A C trampoline is available
  for anything the checker cannot see.
- Userspace builds enable SSE/AVX, NEON and RVV. Only the kernel has FP
  turned off.

Hosting full Swift is a real port. It means building the toolchain's
stdlib, runtime and FoundationEssentials for a Todhchai target, on our own
libc, which must cover about 160 libc symbols for the runtime alone, plus
what FoundationEssentials needs. Under principle 29 these are toolchain.
Foundation's internationalization (ICU-backed) and networking modules are
not used, and the Kits cover locale-aware formatting and networking. Tier 0
does not depend on any of this, so the system boots and runs before full
Swift exists ([roadmap](roadmap.md) M3 against M6).

**Language fallback (principle 28).** Swift is the default. Assembly is used
for entry stubs, context switch and hand-written SIMD kernels. C is used for
calling-convention shims and the small freestanding runtime the compiler
calls (`mem*`, stack guard). GPU code is written in a
shading language compiled to SPIR-V. Every non-Swift file states in its
header why Swift couldn't do the job fast enough.

## 3. Boot and the process tree

```
UEFI ──► croi loader ──► croi kernel ──► userboot (from bootfs, via vDSO)
                                           └─► launcher   (holds root job, root resources)
                                                ├─► devmgr ──► driver hosts (PCI, NVMe, xHCI, HDA, virtio, GPU, …)
                                                ├─► power   (DVFS policy, thermal, device power, profiles)
                                                ├─► block ──► fs (Taisce volumes) ──► indexer
                                                ├─► gpu system driver(s)
                                                ├─► display driver(s)  (scanout, vblank, hotplug)
                                                ├─► compositor  (Radharc, over /svc/display + Vulkan)
                                                ├─► input   (HID class, keymaps, IME host)
                                                ├─► audio   (mixer, device graph)
                                                ├─► tracer · debugd · net · keyring · router
                                                └─► shell: Tracker · Deskbar · Terminal · apps
```

- The croi loader reads `\croi\kernel.elf` and `\croi\bootfs.img` from the
  EFI system partition and passes them in **handoff v2**, which adds bootfs,
  the GOP framebuffer and a command line.
- **userboot** maps bootfs and starts the launcher, as in Zircon.
- **launcher** replaces Fuchsia's 76K-line component manager. It reads small
  manifests, creates a job per service, builds each process's namespace and
  passes handles in. There is no routing graph engine: a manifest names the
  services a process gets, and that is all it gets.
- A service crash is contained. The launcher restarts it according to its
  manifest. Clients see the channel close and reconnect through the SDK.
  Driver hosts and the GPU system driver are designed to be restartable.
  That covers software faults. A driver that touches hardware in the wrong
  state (a register block whose power domain is off, a GPU before its power
  sequence) can hang the bus or reset the SoC, and no process boundary
  helps; the arm64 boards do both
  ([research/hardware-targets.md](research/hardware-targets.md)). Drivers
  for such hardware encode the required order as types where they can
  (a `PoweredBlock` that only exists after its power-on sequence).

## 4. IPC

### Transport
- **Channels** for request/reply and events (message bytes plus a handle array).
- **Shared-memory rings** (a VMO plus a futex word or an eventpair to signal)
  for high-rate data: input events, audio positions, GPU submission, block I/O,
  and the compositor's present queue.
- **Ports** for waiting. Every handle a service gives out can be waited on.

### Interface definition: Swift as the IDL
FIDL is replaced. Protocols are written as ordinary Swift files that are
annotated and checked by a macro:

```swift
@IPCProtocol(id: "todhchai.display.Surface", version: 1)
protocol Surface {
    func present(_ frame: borrowing FrameDesc, acquire: consuming Event)
        throws(SurfaceError) -> PresentToken
    @oneway func setTitle(_ title: borrowing InlineString<128>)
    @event func released(_ buffer: BufferID)
    @since(2) func setLatency(_ frames: UInt8)
}
```

- The **macro** generates `SurfaceClient` and `SurfaceServer` with encode and
  decode over `RawSpan`/`MutableRawSpan`. They allocate nothing and use no
  existentials, so they work in Embedded Swift.
- Messages that carry handles are `~Copyable`, so a handle moves with
  `consuming`. Decoded requests are `~Escapable` views into the receive
  buffer, which makes decoding zero-copy.
- **`idlc`** is a standalone swift-syntax tool that reads the same files. It
  emits C headers and encoders (for C game engines and other languages),
  checks evolution against a recorded API baseline, and produces protocol
  documentation.
- The **wire format** follows FIDL's proven rules: little-endian, 8-byte
  alignment, handles in a side array, a transaction id plus a 64-bit hashed
  method ordinal, and epitaphs (a final status sent before a channel closes).
  The encoding rules are the contract, not Swift layout, and they are
  written down in [wire-format.md](wire-format.md).
- **Cancellation** is part of the wire format: a client can cancel an
  in-flight transaction by id, and the server must answer either the
  original request or the cancel, never both and never neither. This is
  9P's `Tflush` rule, and without it every blocking call needs its own
  thread to be interruptible.
- **Evolution:** `@flexible` enums and unions, table structs with numbered
  optional fields, and `@since(n)` on methods. A change that would break an
  older client fails the build.

## 5. Namespaces and capabilities

- Each process has a **namespace**: a table mapping paths to channels. There is
  no global root. `/svc/...` holds the services it was granted, `/data` is the
  app's own directory, and `/vol/<name>` holds the volumes it may see.
- Processes start with only their namespace and a few startup handles. Every
  privilege, from MMIO to IRQs to an exclusive audio ring, is a handle someone
  passed in.
- **Direct access by grant.** A fullscreen game, profiler or DAW can ask the
  shell, through a user prompt, for direct capabilities: an exclusive
  audio-device ring, raw HID rings, GPU performance counters. The grant is
  recorded in the app's attributes and can be revoked.
- **Bind and union.** Following Plan 9, a path can hold an ordered list of
  channels, each added *before*, *after* or *replacing* what is there, with
  one marked as where new files are created. Uses:
  - a dev SDK layered over the system SDK;
  - per-app font and theme overrides;
  - a freshly built driver or service bound over the system one for testing;
  - a sandboxed app seeing a filtered view of a volume.

  Unions are resolved in the client library: a lookup tries members in
  order only after a miss, the number of members is capped, and directory
  listings are merged without duplicates (Plan 9 shows duplicates).
- **Sealed namespaces.** A process can be started with its namespace
  sealed. It can still bind and rearrange what it holds, but it can never
  attach a channel received from elsewhere, and its children inherit the
  seal. This is Plan 9's one-way `RFNOMNT`, and it is how plugins,
  translators and replicants are sandboxed in one call.
- **Session service board.** Each login session has a board at `/srv`
  where a user's own programs post endpoints by name, as 9front's `/srv`
  does, so they can find each other without a global registry. `/svc` stays
  reserved for services the launcher granted.
- **Manifests fail loudly.** A launcher manifest that names a missing
  service or a bad path stops the launch with an error. Plan 9 silently
  ignores errors in namespace files, and the result is sandboxes that are
  quietly wider or narrower than intended.

## 6. The Node protocol: every service is a browsable tree

Every service implements one small generic protocol alongside its own
typed ones. A granted service appears at `/svc/<name>/` as a Node tree, and
its typed protocols are opened from there. It is shaped like
9P, but channels already supply what 9P's file ids, tags, version and
attach messages exist for.

```swift
@IPCProtocol(id: "todhchai.node.Node", version: 1)
protocol Node {
    func walk(_ names: borrowing NameList) throws(NodeError) -> WalkResult   // ≤ 16 names; partial results show where it stopped
    func stat(_ fields: StatMask) throws(NodeError) -> Stat                  // typed attributes, Taisce style
    func readdir(cursor: UInt64, max: UInt32, fields: StatMask) throws(NodeError) -> DirBatch
    func read(offset: UInt64, max: UInt32) throws(NodeError) -> Bytes
    func write(offset: UInt64, _ data: borrowing Bytes) throws(NodeError) -> UInt32
    func watch(since seq: UInt64) -> NodeEvents                              // change stream; no polling
    @since(2) func create(_ name: borrowing Name, kind: NodeKind) throws(NodeError) -> NodeChannel
    @since(2) func remove() throws(NodeError)
}
```

- Walk results carry a qid (`path`, `version`, `type`) per element, for
  cache validation.
- Leaf nodes hold plain text or typed records, so they are scriptable
  (`cat /svc/audio/status`, `echo latency 64 > /svc/audio/ctl`) and can be
  exported across machines without translation (§19).
- An SDK helper (the equivalent of lib9p's in-memory file tree) lets a
  service publish its tree in about 150 lines. lib9p's complete RAM file
  system is 169 lines.
- **High-rate data never flows through Node.** A node such as
  `/svc/audio/ring` hands out the dedicated protocol channel or ring
  handle, and the data goes there.

The file system (whose protocol extends Node with directories, files,
attributes and queries), Tracker, the Inspector, `hey`-style scripting and
the export bridge all use Node. A typed service protocol is still the
interface apps program against.

## 7. Memory

- Apps reach croi's VMAR and VMO primitives through `Memory` in the SDK:
  `reserve(size, align, at: fixed?)`, `commit`, `decommit`, `protect`,
  `mapView(of: vmo, at:)` and `release`. Reserving 64 GB is cheap.
- **Arenas** are the SDK's default allocator: a growable arena that reserves a
  large range and commits as it grows, plus thread-local scratch arenas. The
  UI Kit and the event loop allocate their per-frame data from arenas.
- **JIT:** inside a reservation, a page can be flipped between writable and
  executable per thread. This needs a manifest entitlement (F-218), for
  emulators, Wine and scripting engines.
- **Memory budgets:** each process sees one budget covering CPU and GPU memory,
  because GPU buffers are VMOs and the kernel accounts them to the owning
  process. It gets one pressure notification on its port. The budget never
  shrinks without notice (F-109; console-style exact budgets).
- **Sharing:** zero-copy everywhere means VMO handles plus a format descriptor
  plus a timeline counter (§10).

## 8. Time, scheduling and power

- **Clock:** the vDSO reads the monotonic clock (TSC, CNTVCT or the RISC-V
  time CSR) with no syscall. A shared read-only page publishes the next vblank
  per output and the CPU's power state.
- **Timers** take an absolute deadline plus a leeway. Real-time intents get
  zero slack. The target is p99 wake error under 100 µs, measured on hardware.
- **Intents:** `Thread.spawn(intent:)` maps to croi profiles:

| Intent | croi profile | Typical use |
|---|---|---|
| `realtime(period, budget, deadline)` | EDF deadline, passes admission | audio callback, compositor latch, input dispatch |
| `frame` | fair, high weight, follows the frame clock | game main thread, render thread |
| `interactive` | fair, high weight | UI threads |
| `throughput` | fair, packed onto one core type | job systems, compilers |
| `background` | fair, low weight, may be coalesced | indexer, sync |

- **Deadline donation:** when a real-time thread makes a channel call (for
  example compositor to GPU driver), the server runs on the caller's deadline
  until it replies. This is a croi extension, after seL4 MCS.
- **Overrun notices:** a real-time thread that exceeds its budget gets a port
  packet, so the audio stack can report overload instead of glitching silently.
- **Isolation:** the foreground app can be given isolated cores, with no other
  threads, timers or interrupts routed to them (Switch-style reserved cores, in
  reverse).
- **Core types:** every target machine mixes them (P/E cores on the
  reference machine; three types on the Sky1). The scheduler places by
  capacity, `throughput` packs onto one type, and `frame` and `realtime`
  threads start on the fastest cores unless a power profile says otherwise.
  The topology page publishes each core's type, capacity and frequency
  domain.

### Power

Power management is split the way the rest of the system is: mechanism in
croi, policy in a user-space **power** service, hardware access in drivers.
The design comes from what AbyssBSD measured on the arm64 boards, and
applies to the reference machine's C-states and P/E cores as well.

- **CPU idle is croi's.** Entering and leaving a power-down state saves and
  restores CPU state, and only the kernel can do that. croi reads the
  states from ACPI (`_LPI` on arm64 with PSCI `CPU_SUSPEND`; `_CST` and
  MWAIT hints on amd64) and picks one per CPU, bounded by the wake latency
  that the deadline threads and real-time interrupts on that CPU allow
  ([croi-requirements.md](croi-requirements.md) §3 item 11). On the Q8B,
  deep idle cost dropped frames until vsync stopped being routed to sleeping
  cores; that rule is built in, not discovered per board.
- **CPU frequency** is the power service's policy over croi's mechanism.
  ACPI CPPC (`_CPC`) where the firmware has it (the Sky1, modern x86 with
  HWP), a SoC driver where it doesn't (the Q8B's EPSS). One policy per
  frequency domain, never one for the whole machine. Admitted deadline
  work sets a floor croi enforces
  ([croi-requirements.md](croi-requirements.md) §3 item 12), so the policy can't starve
  it. The power service also reads the utilization croi publishes rather
  than sampling it.
- **Thermal:** ACPI thermal zones (`_TMP`, `_PSV`, `_CRT`, `_PSL`) through
  the AML interpreter where they work, SoC sensor drivers where they don't
  (the Q8B's TSENS). Passive cooling lowers the frequency ceiling of the
  domains a zone names. Critical temperature shuts down cleanly, and that
  path is tested on each listed machine, not assumed.
- **Device power:** a driver host asks the power service to bring its
  device's power resources, clocks and resets up in order (ACPI `_PR0`,
  `_ON`, SCMI power domains and clocks on the Sky1). Runtime suspend is the
  driver's call, with an autosuspend delay so a GPU doesn't suspend between
  frames (AbyssBSD measured that mistake). GPU and codec DVFS are the
  driver's, by the same per-domain policy.
- **Power profiles** (power-saver, balanced, performance) are one setting
  the power service applies to idle depth, frequency policy and GPU
  policy together, with hooks for drivers. It is a Node tree:
  `echo balanced > /svc/power/profile`.
- **What the system measures:** idle wakeups per second (already a release
  number, principle 9), time per idle state per CPU, and missed frames by
  cause, including "woke from deep idle".

## 9. Drivers

- **devmgr** enumerates ACPI and PCI, matches drivers with **bind rules
  written as Swift predicates**, and starts **driver host** processes. A host
  receives exactly the MMIO, IRQ, BTI and IO-port handles for its device,
  plus, on arm64, an SMC resource limited to the firmware calls its device
  needs. Standard devices often appear as ACPI platform devices rather than
  PCI functions on arm64 (the Sky1's ten xHCI hosts and its HDA controller),
  so the class drivers attach either way.
- **Board database (data, not code).** Firmware tables are sometimes wrong
  for the board they ship on: the Q8B's DSDT describes Qualcomm's reference
  design (applying its GPIO settings would drive USB-C pins), and lacks
  devices that are present (its RTC). A board database keyed on SMBIOS and
  SoC id adds, removes and corrects devices before matching. A quirk lives
  there or in a driver, never in user configuration: AbyssBSD's rule that a
  board-specific setting is a driver bug.
- **SCMI.** On arm64 platforms whose firmware manages power and clocks over
  Arm's SCMI (the Sky1), a small SCMI client service, written from Arm's
  specification, serves power domains, clocks, performance domains and
  sensors to the power service and drivers. The AML interpreter alone isn't
  enough: the Sky1's AML clock methods answer NOT_FOUND for its GPU.
- **ACPI:** devmgr uses our own AML interpreter, written from the ACPI
  specification (no ACPICA), for namespace evaluation, `_PRT` interrupt
  routing, power and thermal methods. It runs in user space, in its own
  process.
- Drivers are ordinary tier 0 processes. They take interrupts from interrupt
  objects bound to a port, or through the IRQ-to-thread fast path for
  real-time devices. They do DMA through BTIs and IOMMU-pinned memory.
- **First driver set**, for QEMU and the reference machine (i7-12700KF,
  RX 6750 XT): PCIe/ECAM, NVMe, AHCI, xHCI plus USB HID, mass storage and
  USB audio, HDA, virtio (blk, net, gpu, input, sound), the GOP framebuffer,
  a PS/2 fallback, and the NIC on the reference motherboard (to be recorded;
  an e1000e/igc-class part is the expected case). **USB CDC-NCM/ECM** is the
  standard-class network fallback on any machine whose NIC has no
  documentation.
- **arm64 driver set**, after the reference machine works (see
  [research/hardware-targets.md](research/hardware-targets.md)):
  - both boards: GICv3/ITS and the timers in croi, PSCI, NVMe, xHCI, the
    GOP framebuffer and the display takeover (§10);
  - Orange Pi 6 Plus: SCMI over its mailbox and SMC, CPPC, ACPI thermal,
    the SBSA watchdog, PL011, HDA as a platform device (ALC269), the CIX
    timer for deep idle, SMMUv3; its RTL8126 NICs have no public datasheet;
  - Radxa Dragon Q8B: the GENI UART, EPSS, TSENS, the two MMU-500s within
    the hypervisor's rules, and starting the ADSP (its fan runs at full
    speed until the ADSP's firmware does). Its audio, USB-C and NIC sit
    behind Qualcomm firmware protocols and an undocumented chip, and come
    last.
- **HID class service:** a userspace service normalizes devices into one
  record per device class (keyboard, pointer, pen, gamepad). Gamepads use a
  controller database stored as data, so SDL's 50K-line HIDAPI layer is
  unnecessary (F-214).

## 10. Graphics

Full design: [desktop.md](desktop.md).

- **Display is its own driver.** A display controller is a separate device
  from the GPU on both arm64 boards (from different vendors on the Sky1),
  and only partly the same device on AMD (DCN inside the GPU). So display
  is its own service behind `/svc/display`: outputs, modes, planes,
  vblank, hotplug and the display timeline. On AMD the GPU system driver
  implements it; on an SoC a display driver host does. Either way the
  compositor sees one protocol. Display drivers come in three tiers:
  1. **Firmware framebuffer:** the GOP framebuffer the loader hands over.
     Copy into it; the display timeline is synthesized from the timer at
     the mode's refresh rate, and present feedback says the times are
     estimates.
  2. **Takeover:** keep the pipeline UEFI left running (its mode, link and
     clocks) and drive only what flips need: the scanout address and
     flush, and the vsync interrupt. That gives real vblank timestamps,
     page flips and direct scanout with none of the PHY, link-training and
     clock code. AbyssBSD's `msmfb` does this on the Q8B. Saving UEFI's
     registers and restoring them when the compositor exits gives the
     console back.
  3. **Full:** mode setting, link training, hotplug of new outputs, planes,
     color pipelines.
- **GPU driver model (Magma-shaped).** Each app loads an in-process
  **Vulkan client driver**, our own. It is written in Embedded Swift and
  exports the Vulkan C ABI, so C and C++ engines can load it without the
  full Swift runtime. It talks to a
  **GPU system driver** process that owns the device: the rings, the GPU
  virtual memory, firmware loading, and the display engine for that GPU.
  Command buffers go through a shared submit ring with a doorbell, not one
  message per submit. A fault in one client kills only that client's
  connection (device lost).
- **Our Vulkan stack** (principle 29) consists of:
  - the loader;
  - the Vulkan headers and dispatch tables, generated from Khronos `vk.xml`;
  - a SPIR-V front end and optimizer shared by every driver;
  - one back end per GPU family that compiles SPIR-V to that family's
    instruction set, from the vendor's published ISA documentation;
  - per-family command-buffer encoding, and the system drivers.

  The shader compiler is the largest single piece and the reason the
  pipeline-cache service (F-103) matters.
- **Buffer objects:** one GPU buffer type everywhere. It is a VMO, plus a
  format and modifier, plus a timeline counter (F-107). The same object
  carries a game's swapchain image, a video frame, a compute result or a
  screenshot.
- **Buffer negotiation:** a much smaller version of sysmem. Producers and
  consumers state their constraints (formats, modifiers, alignment,
  contiguity, **physical address limit**, coherency) and the allocator
  returns buffers that every party can use. Direct scanout depends on this.
  On the Q8B the display only reads contiguous memory below 4 GB, from a
  pool reserved at boot. Formats include the video ones (NV12, P010, and
  vendor-compressed layouts as modifiers) so a hardware codec can hand
  frames to the display without a copy when one exists.
- **Staged driver path.** Each stage is ours. The guest side of a VM
  protocol is written from that protocol's specification.
  1. **No Vulkan:** the GOP framebuffer and the compositor's CPU path. Apps
     use CPU surfaces, and Loinnir waits for stage 2 (it already runs hosted
     on Linux).
  2. **Venus client driver over virtio-gpu (QEMU).** Venus serializes Vulkan
     calls to the host's driver, and its protocol is generated from a
     published XML description, much like `vk.xml`. This gives us real,
     hardware-accelerated Vulkan with no shader compiler of our own. It is
     the first Vulkan Todhchai has, and everything above the driver is built
     on it.
  3. **Our AMD client driver over virtio-gpu native context.** In a VM,
     this runs our own SPIR-V-to-RDNA compiler and command encoding against
     the host's kernel driver. It is the stepping stone that separates "is
     our compiler right?" from "is our system driver right?".
  4. **Bare-metal AMD:** our system driver (rings, GPU virtual memory,
     firmware loading, display engine) from AMD's published documentation.
     Where documentation is missing, we reverse engineer the hardware's
     behavior.
  5. **Intel** (from Intel's published PRMs).
  6. **NVIDIA**, last, largely by reverse engineering.

  **arm64 GPUs.** Neither the Mali-G720 (Sky1) nor the Adreno 690 (Q8B) has
  a published ISA, so each is a reverse-engineering project with its own
  compiler back end, scheduled after AMD
  ([roadmap.md](roadmap.md) M10). Until then the boards use display tiers
  1–2 and CPU composition. The Sky1 gives the OS EL2, so Todhchai can also
  run there in a KVM guest with the Venus client driver over the host's
  Vulkan, which puts Vulkan apps on arm64 silicon long before a native
  driver.
- **Optional:** a CPU Vulkan implementation for CI and headless use. It is
  only worth writing if it doubles as a test oracle for the shader
  compiler.

## 11. Storage

Full design: [filesystem.md](filesystem.md).

- The **block** service runs on NVMe/AHCI/virtio-blk drivers and exposes
  shared-memory submission and completion rings with per-request cache policy.
- The **fs** service implements Taisce: typed attributes, indices, queries,
  live queries and a persistent change journal. Later stages add copy-on-write,
  checksums and snapshots.
- **File I/O:**
  - Opening a file returns a channel plus a kernel **stream** object, so read
    and write run at syscall speed.
  - `backingMemory()` returns a VMO for mmap, served by croi's pager.
  - Async batched I/O goes through a ring to the fs server. Its completions
    arrive on the app's port.
  - Directory listings stream entries with their stat fields and requested
    attributes in one batch, File Pilot style.
- The **indexer** consumes the change journal and builds full-text and content
  indices outside the file system, in the Spotlight style. Content extraction
  uses translators that run as sandboxed processes.

## 12. Audio

- The **audio** service owns devices and a **system mixer with a fixed
  period** (for example 128 frames at 48 kHz, about 2.7 ms). It runs on a
  real-time thread and mixes from shared-memory rings. The period is fixed
  while the device runs, but chosen from the device's constraints: the
  Q8B's DSP path takes only whole milliseconds (multiples of 48 frames at
  48 kHz), and anything else buzzes at the block rate. Apps see the chosen
  period in the stream contract.
- App streams are pull (a callback on an SDK-created real-time thread that
  passed admission) or push (a write call). Each stream has a **contract**
  record: period, rate, end-to-end latency, the anchor between device clock
  and monotonic clock, and a stable device id. Changes to the contract arrive
  as events (F-216).
- **Voices:** `Mixer` voices for one-shot and looping sounds. A beginner
  plays a sound in one call.
- **Exclusive mode:** a granted DAW or game can map the device DMA ring
  directly, where the device has one (HDA, USB audio). A device behind a
  DSP (the Q8B) has no ring to hand out, and exclusive mode there means the
  smallest period the DSP accepts.
- The Media Kit adds BeOS-style node graphs with per-node latency accounting
  on the same rings.

## 13. Input and text

- The input service runs above the HID class service. It turns key events
  into USB HID usage, post-event modifiers, the unmodified character for the
  active layout, and server-generated repeat (F-210).
- Pointer events carry high-rate unaccelerated and accelerated deltas. Pointer
  lock and confinement are server-side (F-213). Pen fields come from HID
  digitizer usages (F-212).
- The **IME** runs beside the compositor. Apps get preedit, commit and
  delete-surrounding events, and report a caret rectangle and surrounding text
  (F-211).
- The focused window gets input through a **shared-memory ring**, so reading
  input costs no IPC (Horizon HID).
- Input events carry hardware timestamps, which lets the tracer measure
  input-to-photon latency end to end.
- **Text stack (ours):**
  - an OpenType shaping engine written from the OpenType specification and
    Unicode's text-segmentation, bidi and line-breaking annexes, with
    script support added in priority order (Latin, Greek and Cyrillic, then
    CJK, Arabic and Hebrew, then Indic);
  - a TrueType/CFF rasterizer and our own MSDF generator;
  - a glyph atlas and glyph cache.

  Unicode property tables are generated from the Unicode Character
  Database, which is the specification. Worst-case Unicode must be fast,
  and termbench is an acceptance test. The shaper is checked against the
  OpenType specification's examples and our own conformance suite.

## 14. Apps, packaging and updates

- **An app is one file:** an ELF executable with an appended resource archive
  (icons, assets, translations, manifest). The file has Taisce attributes: type
  `application/x-todhchai-app`, signature, version and requested capabilities.
  Copying the file installs the app, and deleting it uninstalls it.
- Apps link `libtodhchai` and Vulkan dynamically, against a versioned **API
  level**, and everything else statically. `libtodhchai` is built in
  Embedded Swift, so linking it never pulls in the full Swift runtime. A
  static `libtodhchai` is available for apps that want no dynamic
  dependency besides Vulkan, at the cost of updating with the app instead
  of the OS. This works because the real boundary is the versioned IPC
  protocols underneath. Availability annotations are
  checked at build time. An optional service is a capability the app requests,
  so a missing one is an open error, not a `dlopen` probe (F-219).
- **System updates:** the system image is a read-only, signed volume. An
  update writes a new image, and boot switches between images atomically. With
  snapshots (Taisce S2), user data is snapshotted before each update.
  Nothing updates without the user asking.

## 15. Compatibility

Under principle 29, Todhchai provides **platform interfaces**, all written
by us. Other projects port themselves onto those interfaces, and their code
never enters the Todhchai tree.

**What Todhchai provides** (in priority order, by NeoDarwin Q5 reach per
unit of effort):
1. **POSIX:** our libc plus an fdio-style shim, with epoll, eventfd and
   memfd shims. Ported software sees Todhchai as a Linux-like Unix with its
   own `__todhchai__` macro.
2. **Vulkan**, through our drivers, published as a profile whose floor is
   what DXVK-class translation layers need (Vulkan 1.3 plus their required
   extensions).
3. A **Wayland "core+"** server built into the compositor (core plus 16
   extensions), written from the protocol XML, for GTK, Qt and
   Wayland-native apps.
4. The F-218 memory APIs (reservations, views, per-thread W^X) that
   emulators and translation layers depend on.

**What third parties bring**, either upstream or in a separate ports
collection, never in the Todhchai tree:
- an **SDL3** backend for Todhchai, contributed to SDL upstream. It brings
  the SDL game catalogue;
- **WebGPU** implementations (Dawn, wgpu) and **GL through Zink**, running on
  our Vulkan;
- later, **Wine** with DXVK and vkd3d-proton.

We can help with these ports, but they belong to their own projects. Darwin
and Metal compatibility are explicitly out of scope.

## 16. Observability and debugging

- **tracer:** a system-wide timeline built from croi ktrace, userspace trace
  points and GPU timestamps. It is always available and cheap to turn on. It
  records scheduling, IPC, wait reasons, frame and present events, and audio
  callbacks, all as plain data. Flow ids join a request's spans across
  processes, and the generated IPC code writes them, so every service is
  traced with no code of its own. It samples stacks on the tick and on PMU
  overflow, and a flight recorder keeps the last seconds for crashes and
  missed deadlines. The performance budgets are measured from it, from M1
  hosted and M3 native ([performance.md](performance.md)).
- **Self-inspection:** each process can read its own thread, wait-reason,
  memory-map, handle and queue tables through `/svc/self`.
- **debugd** exposes a stable, library-shaped debug protocol: attach, threads,
  registers, memory, breakpoints, exception channels, and module load and
  unload events. Native debuggers and third-party ones (RemedyBG and RAD
  Debugger style) use the same API. From Plan 9's `/proc` and acid:
  - **Start suspended:** launch a program stopped before its first
    instruction (acid's `hang`), so a debugger can attach before anything
    runs.
  - **Post-mortem:** a crashed process is kept in a frozen state for a
    while (Plan 9 keeps the last four "Broken" processes), so a debugger
    can attach after the fact. The crash is also sent through the router as
    `type=todhchai/crash`.
  - **Remote:** the debug protocol works unchanged over the export bridge
    (§19), so you can debug a game on a test machine from your dev box, as
    acid does by importing a remote `/proc`.
  - **No string signals:** Plan 9's notes are text strings, only five can
    be queued, and extras are silently dropped. Asynchronous events reach a
    process as typed port packets and exception-channel messages instead.
- **Hot reload:** loaded modules are never locked. The SDK's `CodeModule`
  loads a shared object, hands it a state block at a fixed address, and swaps
  it on rebuild (Handmade Hero day 21). Record and replay comes from
  snapshotting the reserved range.
- **Debug info:** our own fast, indexable format, with our own reader and
  writer, designed from what RAD Debugger's RDI shows works. It is
  converted from DWARF at link time for fast loading. The toolchain still
  emits DWARF, so the converter reads DWARF, written from the DWARF 5
  specification. Decided 2026-10-09 (roadmap, "Decided").

## 17. Security model

- There is no ambient authority. Authority is handles and namespaces (§5).
- Drivers, the file system, the compositor and the GPU system driver are each
  their own process. DMA goes through the IOMMU (BTI), which is core to croi.
  **Exceptions are explicit.** Some DMA masters have no IOMMU in front of
  them (the Sky1's video codec; GPUs that use their own MMU), and some
  IOMMUs belong to firmware or a hypervisor (the Q8B's). A driver for such
  a device gets a BTI with no IOMMU, its host is part of the trusted base,
  and the hardware list says so for each machine.
- **App sandbox:** by default an app sees `/data` (its own directory), files
  the user picked through the file chooser (which hands over a handle), and the
  basic SDK services. Anything more is a capability in its manifest that the
  user approves.
- **Replicants** (BeOS desktop widgets) run out of process and embed their
  surface through a view token, in a sealed namespace (§5). They never load
  code into Tracker or Deskbar.
- **Encryption:** each volume has its own key. The key hierarchy starts with
  the user's key.
- **keyring** is the authentication agent, modeled on Plan 9's factotum.
  It holds every long-term key and runs authentication and signing
  protocols for apps, which only pass bytes between the keyring and the
  peer. An app gets back a session secret (usable as a TLS pre-shared key
  or channel key) and the peer's identity, never a long-term key.

  ```swift
  @IPCProtocol(id: "todhchai.auth.Keyring", version: 1)
  protocol Keyring {
      func startSession(_ pattern: borrowing KeyPattern, role: Role) throws(AuthError) -> AuthSessionChannel
      func sign(_ digest: borrowing Digest, key: borrowing KeyPattern) throws(AuthError) -> Signature
  }
  // AuthSession: next() -> .send(bytes) | .need(count) | .needKey(pattern) | .needConfirm | .done(AuthInfo); feed(bytes)
  ```

  - **Confirmation:** a key can require confirmation (`always`,
    `once-per-session`, `never`). Requests for confirmation or for a
    missing key go to one trusted shell prompt, which shows *which app is
    asking*. Plan 9 doesn't track the requesting app; we record it per
    session.
  - **Scope:** each app gets its own keyring session channel, limited by
    its manifest to the domains and protocols it may request. There is no
    global mount anyone can open.
  - **No secret export by default:** revealing a password (Plan 9's
    `proto=pass`) is a separate, confirmation-gated capability.
  - **Hardening:** debugd refuses to attach to the keyring, and its memory
    is never paged out unencrypted. Keys at rest live in an encrypted
    keybag on the user volume, unlocked at login, and the same root key
    derives the volume keys.
- **Cryptography is ours** (principle 29), written from the standards:
  - FIPS 180/202 (SHA-2, SHA-3);
  - FIPS 197 plus IEEE 1619 (AES, AES-XTS);
  - RFC 8439 (ChaCha20-Poly1305);
  - RFC 7748 and 8032 (X25519, Ed25519);
  - RFC 8446 (TLS 1.3);
  - the BLAKE3 specification.

  Because this is the riskiest code to write ourselves, it gets:
  - constant-time implementations checked by a CI timing harness;
  - the official test vectors (NIST CAVP, the RFC appendices, Wycheproof
    vectors used as data);
  - differential fuzzing against the host's crypto in hosted mode;
  - an external review before any release that ships TLS.

## 18. Hosted mode

The SDK, compositor, UI Kit and file system all get a **Linux host backend**
from the start, as the NeoDarwin study did with its macOS shim. Each one runs
as an ordinary program on Linux: the compositor as a Wayland client
first, and later a fullscreen DRM/KMS client for latency work, and the file system as a FUSE server or a disk-image
tool. This lets user-space design and measurement go ahead in parallel with
croi's path to user space. The native backend replaces the host one piece by
piece.

The host backend calls the host's own system interfaces: Linux syscalls,
the host's Vulkan loader and driver, `/dev/fuse` and the Wayland socket.
Those are the platform it runs on, not code in our tree. Wherever a
protocol is involved, we speak it directly (the FUSE kernel protocol, the
Wayland wire protocol) rather than vendoring libfuse or libwayland.

**A development tool, not a product** (decided 2026-10-09). Inferno ran the same applications
hosted on Windows, Linux and Plan 9 as on bare metal, and that reach is
something a new OS rarely gets. Shipping hosted Todhchai (SDK plus desktop
in a window) on Linux, macOS and Windows would let developers target
Todhchai years before they own a machine running it. The cost is that the
host backend becomes a product with users, and it gets pulled toward each
host's rules. NeoDarwin's macOS shim needed about 1,100 lines just to hide
AppKit's main-thread and modal-loop rules. So the host backend runs on
Linux, for developing and measuring Todhchai, and is not shipped. See
[roadmap.md](roadmap.md), "Decided".

## 19. Remote access: the export bridge

The **export bridge** serves a chosen subtree of a process's namespace to
another machine, like Plan 9's `exportfs`, `rimport` and `rcpu`. A remote
client mounts it into its own namespace.

- **Carries:** Node trees (`/svc/...` inspection and control), file
  volumes, the tracer's stream, and debugd (read and control).
- **Never carries:**
  - shared-memory rings or raw handles to local hardware;
  - the keyring, except an explicit, confirmation-gated forwarding of one
    session;
  - the compositor protocol, until a dedicated remote-display design exists
    (the layer-tree protocol makes that easier than sending pixels, but it
    needs its own design).
- **Authentication:** a keyring session. Its session secret becomes the
  transport key, so your own machines need no certificates. This is the
  Plan 9 pattern (`tlsclient` uses factotum's secret as a TLS pre-shared
  key).
- **Pipelined:** many requests in flight, with streaming reads. Plan 9's
  mount driver does one synchronous round trip per chunk, which makes
  remote bulk reads slow.
- **Resumable:** messages are numbered and acknowledged, and unacknowledged
  ones are replayed after a reconnect, as `aan` does. A laptop changing
  networks doesn't kill a remote debug session.
- **Identity:** the bridge renumbers node identities (qids) per export, as
  `exportfs` does, so two exported volumes can't collide.

## 20. Foundations we write, and what we write them from

Principle 29 means each of these is a Todhchai component, written from the
listed sources and checked by the listed suites. Data files that *are* the standard (Unicode Character Database,
Khronos and Wayland XML registries, the IANA time-zone database, USB-IF HID
usage tables) feed our generators.

| Component | Tier | Written from | Checked by |
|---|---|---|---|
| libc + POSIX shim + dynamic linker | 0/1 | ISO C23, POSIX.1-2024, ELF and the psABIs | libc conformance tests we write; running the toolchain's own test suites on Todhchai |
| AML interpreter | 0 | ACPI 6.5 | firmware tables from real machines and QEMU |
| Drivers (NVMe, AHCI, xHCI, HID, HDA, USB Audio, virtio, NICs) | 0 | NVMe, AHCI, xHCI, USB, HID, HDA, UAC and virtio specs; vendor datasheets | QEMU devices and hardware in CI |
| Vulkan loader, client drivers, SPIR-V front end, ISA back ends, system drivers | 0/1 | Vulkan and SPIR-V specs (`vk.xml`, SPIR-V grammar JSON), Venus protocol XML, virtio-gpu spec, AMD ISA guides and register docs, Intel PRMs, reverse engineering | the Vulkan CTS run as an external test tool, plus our own tests |
| Text: shaper, rasterizer, MSDF, segmentation, bidi | 1 | OpenType 1.9, Unicode UAX #9/#14/#29, UCD | conformance files published with the Unicode standard; our shaping suite |
| Compression: zstd, LZ4, DEFLATE | 0 | RFC 8878, LZ4 frame format, RFC 1951/1952 | round trips and published test files |
| Crypto and TLS | 0 | FIPS, RFC and BLAKE3 specs (§17) | NIST CAVP, RFC vectors, Wycheproof vectors used as data |
| Image codecs (PNG, JPEG, WebP, QOI) and audio codecs (WAV, FLAC, Opus, Vorbis) as translators | 1 | W3C PNG, ITU T.81, RFC 9649, RFC 6716 and the format specs | reference test images and streams |
| Wayland server | 1 | Wayland protocol XML and documentation | GTK and Qt clients ported by their own projects |
| File systems: Taisce, FAT/exFAT, read-only BFS and ext4 | 0 | our design; Microsoft's FAT and exFAT specs; Giampaolo's book; the ext4 on-disk documentation | crash harness, shadow-model fuzzer |
| Debug-info reader and writer, debugger | 1 | DWARF 5, ELF | toolchain output |

**Not ours, by the toolchain exception:**
- Swift (compiler, stdlib, runtime, concurrency runtime) and
  FoundationEssentials;
- clang, LLVM, lld and compiler-rt;
- LLVM's libc++, libc++abi and libunwind, as far as the Swift runtime
  needs them;
- swift-syntax;
- offline SPIR-V shader compilers.

**Decided edges of principle 29:**
- **GPU and device firmware** is part of the hardware. The user installs it
  from the vendor's redistributable files, and the system driver loads it
  by name and version. It is never in our tree or our system image.
- **Data is data:**
  - fonts;
  - the Unicode, tz and HID tables;
  - gamepad mapping databases and PCI/USB ID names;
  - test vectors and conformance corpora.

  These are used under their licenses, kept in a `data/` area apart from
  source, with their provenance recorded.
