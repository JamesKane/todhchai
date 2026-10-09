# Design principles

These are the rules every Todhchai component is judged against. Each one cites
where it comes from. The research notes are in [research/](research/):

| Key | Source |
|---|---|
| `ND` | the NeoDarwin API study ([digest](research/neodarwin-digest.md)); `F-nnn` are its friction entries |
| `HM` | the Handmade discussions ([notes](research/handmade.md)); `HM §3.n` is principle n in Part 3 |
| `BE` | the BeOS and Haiku record ([systems research](research/systems.md) §A–B) |
| `SY` | the systems research ([notes](research/systems.md)): BeFS, compositors, Swift, UI |
| `CR` | the croi assessment ([notes](research/croi-assessment.md)) |
| `P9` | the 9front source studies ([desktop](research/9front-desktop.md), [system](research/9front-system.md)) |

Section I (ownership) is a hard rule and overrides every other principle.
Among the rest, when two principles conflict, the earlier one wins.

## A. The app owns the machine it was given

1. **The platform is a library the app calls, never a framework that calls the
   app.** The app owns `main` and its loop. No API is tied to the first thread,
   there is no main-thread rule, and nothing runs a nested or modal loop inside
   a platform call. Dialogs, menus, drags and interactive resize are async state
   machines that report through events. (HM §3.1; ND F-201, F-202; ND heritage:
   "semantics baked into v1 can never be removed".)

2. **One wait for everything.** A thread waits on one port, and every source
   arrives there: window events, the frame clock, timers, audio contract changes,
   I/O completions, IPC, its own wakes. Every service hands out a waitable handle.
   (ND heritage §1–2, Exec `Wait`, GEM `evnt_multi`; croi `port_wait`.)

3. **Time is absolute.** Sleeps and timers take an absolute deadline plus a
   leeway. There is no global resolution knob. Frame timing comes from the
   compositor's clock and reports when frames actually reached the glass.
   (ND F-101, F-102, F-203; HM §3.10.)

4. **Memory is the app's to arrange.** The memory API is reserve, commit,
   decommit, protect, map view and release, with an optional fixed base address.
   The SDK's default allocator is an arena with scratch arenas. A malloc-style
   heap is available but never required. (HM Fleury; ND F-218; Handmade Hero
   record/replay.)

5. **Threads state intent, not priority.** Threads are created with an intent
   (`frame`, `interactive`, `throughput`, `background`, `realtime(period,
   budget, deadline)`). Real-time requests pass an admission test that accepts
   or refuses them with a reason, inside a per-user budget, with no privilege
   needed. (ND F-204, F-215; croi deadline profiles.)

## B. Thin layers, honest costs

6. **Every layer must pay rent.** A layer exists only if it makes something
   pleasant that would otherwise be painful, and it must never be the only way
   through. Below each convenience layer is a documented layer you can use
   directly: the immediate-mode UI kit sits on the 2D renderer, which sits on the
   GPU library, which sits on Vulkan, which sits on the GPU driver protocol. (HM
   non-pessimization; Thirty-Million-Line problem.)

7. **Fast paths are shared memory, not messages.** High-rate state (input
   events, audio positions, frame timing, GPU submission, block I/O) moves through
   shared-memory rings with one notification handle. Messages are for control.
   (ND heritage §6, Horizon HID; CR §4.6.)

8. **Grow APIs out of real programs.** Every SDK surface is designed against a
   reference program (game loop, text editor, synth, compute-to-display, file
   browser) and measured. Nothing gets speculative generality. The bar for
   window, frame, input and sound together is about 12 calls, which is what the
   Amiga and the Switch needed. (HM semantic compression; ND R14, S7.)

9. **Performance numbers block releases.** Boot time, app cold start, idle
   wakeups, input-to-photon latency, frame-timing error, audio underruns, the
   termbench result, directory-listing speed and whole-OS build time (clean
   and incremental, per component) are tracked in CI and gate releases.
   Each number is a budget enforced from the milestone that introduces it,
   measured from the tracer, so a violation can be profiled with the tool
   that found it ([performance.md](performance.md)). (HM §3.20; ND S7
   criteria; P9 `mk all` timing its own build; NeoVectra's budgets, which
   went unmeasured for five milestones.)

10. **Line count is a budget.** Every system component publishes its size and
    dependency graph. The boot path has a line budget. Because every line in
    the system is ours (principle 29), the budget measures the whole OS.
    Development toolchains are outside it. (HM manifesto; Thirty-Million-Line
    problem.)

## C. Stable, language-neutral boundaries

11. **The system ABI is IPC protocols plus C.** No Swift or C++ type layout ever
    crosses a library or process boundary. System services speak versioned IPC
    protocols. `libtodhchai` exports a C ABI with size-versioned structs and
    generation-checked handles. Swift is the implementation language and the
    nicest client, but C, Zig, Odin, Rust and Jai are full citizens. (BE fragile
    C++ ABI; CR §5, Embedded Swift has no library evolution; HM §3.6.)

12. **Handles are index plus generation everywhere.** Process-local objects
    across the C ABI use 64-bit `{index, generation}` handles. A stale handle is a
    diagnosed no-op, never a crash. Kernel handles are `~Copyable` in Swift.
    (ND C9, R8.)

13. **Errors are values.** Swift APIs use typed throws. The C ABI returns codes
    plus a thread-local detail. No exceptions cross a boundary, and resize or
    surface reconfiguration is a state, never an error. (ND C13, R12.)

14. **v1 promises are permanent, so v1 promises little.** Every protocol has a
    version, capability queries and evolution rules (flexible enums, numbered
    optional fields) from day one. Anything we are unsure of stays out of v1.
    (ND FreeMiNT lesson; CR §3 FIDL evolution.)

## D. Data you can see and query

15. **Files carry typed attributes, and the file system answers queries.**
    Indexed attributes, queries and live queries are core file system features,
    not a search daemon bolted on. A persistent change journal backs every
    notification. (BE BFS; SY §A.)

16. **The system shows what it is doing.** Every process can inspect its own
    threads, wait reasons, memory map (reserved vs committed), handles, I/O
    queues and GPU queues. A system-wide timeline tracer is always available and
    cheap to turn on. Debug state is plain data. Every service exposes a small
    browsable tree (`/svc/<name>/`) of status, control and per-object nodes,
    through one generic Node protocol, so `cat`, scripts, the Inspector and a
    remote machine can all read it. (HM §3.13, Visibility Jam; croi ktrace;
    P9 `/proc`, `/net`, rio's `wctl`.)

17. **Debugging and hot reload are OS services.** There is a stable, library-
    style debug API (attach, threads, memory, breakpoints, exceptions, symbols).
    Loaded code is never locked, so it can be rebuilt and swapped while the
    process runs. One fast debug-info format is native. (HM Blow, Fleury, HH day
    21.)

## E. The user owns the machine

18. **Apps are single files, and installing one means copying it.** An app is
    one file (an ELF with an appended resource archive, carrying its type and
    metadata as file system attributes). There are no installers and no registry.
    Removing the file uninstalls it. App data lives in a per-app directory the
    user can see. (HM §3.5.)

19. **No telemetry, no forced updates, no account.** System updates are
    explicit, atomic (a snapshot plus image swap) and reversible. The root of
    trust is the user's key. (HM §3.17.)

20. **Capabilities, not ambient authority.** A process gets only what it was
    handed: a namespace and handles. A fullscreen game, a profiler or a DAW can
    be granted direct rings to the GPU, audio DMA and input devices, under the
    same capability rules as everything else. Namespaces support bind and
    union directories so they are pleasant to compose, and a **sealed**
    namespace (inherited, can never be unsealed) lets a sandbox rearrange
    what it has but never attach anything new. Apps never hold long-term
    secrets: a keyring agent runs the authentication protocols for them. (CR
    §3 namespace model; HM §3.18; P9 `RFNOMNT`, factotum.)

## F. Hardware

21. **Standard device classes first, and a published hardware list.** Drivers
    target standard interfaces (NVMe, xHCI, HDA/USB Audio, virtio, GOP, HID,
    AHCI) before vendor-specific ones. Supported hardware is a short, published,
    console-like list that grows on purpose. (HM §3.19; Thirty-Million-Line
    problem.)

22. **Vulkan is the only native GPU API.** The drivers are our own,
    structured the Magma way: a client driver library runs in each app, and a
    system driver process owns the device. The SDK's GPU library is built on
    Vulkan, and so is any third-party layer someone ports (WebGPU, GL, D3D
    translation). SPIR-V is the only shader IR. Pipelines are never compiled
    at first use. (ND F-103, F-104, F-111, Q5; SY §C.)

## G. Look and feel

23. **Games and real-time audio get priority over effects.** The compositor
    tries direct scanout first, then hardware planes, and composites only as a
    last resort. Visual effects apply only to desktop chrome, are cached by
    damage, and turn off when a game is presented directly or the frame budget
    is tight. (SY §C; Windows Independent Flip, gamescope.)

24. **Retro-future style comes from cheap shapes, not expensive post-processing.**
    SDF text and shapes give glow, outlines and cut corners in one shader. The
    CRT/scanline pass is optional, and there is always a high-contrast,
    no-flicker accessibility theme. (SY §E.)

25. **The shell uses the public SDK.** Tracker, Deskbar, the terminal and every
    system app are built on the same public kits a third party gets, so their
    gaps show up early. (HM §3.12; BE.)

## H. Composition

26. **A host serves what it consumes.** The compositor is a client of the
    same protocol it serves, so a desktop can run inside a window, and an IDE
    or terminal can host GUI tools in a pane by handing them a
    compositor-shaped endpoint. Nesting is tested in CI. (P9 rio-in-rio,
    acme over `/mnt/wsys`.)

27. **Apps extend each other through intents, not plugins.** One router
    service carries "open this", "show this location" and "run this" between
    apps by rules over type, attributes and content (the Plan 9 plumber).
    An app's user intents can be claimed by an outside process, which either
    handles each one or declines it so the app runs its default (acme's
    `event` file). No foreign code runs in another app's process. (P9
    plumber, acme; BE replicant lesson.)

## I. Ownership

These two rules override every other principle.

28. **Swift first, at the right level.** New libraries are written in Swift:
    Embedded Swift for tier 0 (kernel-adjacent services, drivers, real-time
    paths), full Swift for tier 1 (apps, Kits, tools). We fall back to
    another language only when Swift cannot do the job with the required
    performance. Each fallback is recorded in the file's header comment
    with the reason and, where possible, a measurement. Cases expected
    today:
    - assembly for entry stubs, context switch and SIMD kernels Swift can't
      express;
    - C for calling-convention shims and the compiler runtime;
    - a shading language for GPU code, compiled to SPIR-V.

    This extends croi's rule ("C or assembly only where Swift cannot do the
    job") from *can't* to *can't fast enough*. "Swift is slower" is a claim
    to measure, not assume.

29. **Everything in the project is ours. Foundations are clean-room.** The
    Todhchai tree contains no third-party code: no vendored libraries, no
    submodules, no ports of other projects' source. croi is ours too, kept
    as an independent project. Where a foundation is needed (libc, text
    shaping, font rasterization, compression, cryptography, image and audio
    codecs, the ACPI interpreter, Vulkan drivers and their shader compiler,
    the Wayland server), we write it from:
    - **specifications:** ISO C, POSIX, RFCs, Unicode, OpenType, Khronos
      Vulkan and SPIR-V, virtio, PCIe, NVMe, USB, HID, ACPI, UEFI, IEEE/NIST
      crypto standards, and the Wayland protocol XML;
    - **vendor hardware documentation**, such as AMD's ISA guides and Intel's
      PRMs;
    - **reverse engineering** where documentation does not exist.

    **Data is data, not code.** Third-party data can be used under its
    license and is kept separate from source, with its provenance recorded.
    That covers:
    - standards registries, such as Khronos `vk.xml`, the Unicode Character
      Database, the Wayland protocol XML, IANA tzdb and the USB-IF HID
      tables;
    - community databases, such as gamepad mappings and PCI/USB ID names;
    - fonts, keymaps, test vectors and conformance corpora.

    Code generated from such data by our own generators is ours.

    **Firmware is hardware.** Vendor firmware that a driver loads onto a
    device (GPU microcode, Wi-Fi firmware) counts as part of the device. It
    is never in our tree. The user installs it from the vendor's
    redistributable files, and the driver loads it by name and version.

    **Studying other systems is research, not reuse: "study designs, never
    copy code".** We read other designs and source, cite them and adopt
    their ideas, as the research notes do. We never copy or translate their
    code. An implementation is written from the specification and our own
    design notes, and its file header names the specifications it follows.
    This rule governs Todhchai. croi has its own directives.

    **The exception is development toolchains.** We use, and do not rewrite:
    - the Swift compiler, together with the standard library, runtime and
      concurrency runtime it ships (they are the language's support
      libraries), and the core of swift-foundation (`FoundationEssentials`)
      for tier 1. Foundation's internationalization (ICU-backed) and
      networking modules are excluded, and the Kits cover those needs;
    - clang, LLVM, lld and compiler-rt;
    - swift-syntax, for macros and `idlc`;
    - offline shader compilers that produce SPIR-V.

    A toolchain runs at build time. Apart from the language runtime and
    FoundationEssentials, nothing from a toolchain is linked into what
    Todhchai ships.

    **Third-party software still runs on Todhchai.** Apps may bundle
    whatever they like, since single-file apps carry their own dependencies.
    Ports of other projects (SDL, WebGPU implementations, GL or D3D
    translation, Wine) live in their own upstream trees or in a separate
    ports collection, never in the Todhchai tree or the system image.
