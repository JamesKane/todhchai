# Handmade circle on better operating systems: research notes for Todhchai

Compiled 2026-10-09. Every claim is tagged with how well it is sourced:
- **[V]** I read it in the primary source during this research.
- **[S]** I found it only in a secondary source or summary.
- **[U]** Unverified. It comes from general knowledge of the talks or streams and should be checked before anyone quotes it.

---

## Part 1: Sources and concrete claims

### Casey Muratori

**1. "The Thirty-Million-Line Problem" (talk 2015; blog page dated 2018-05-21)**
URL: https://caseymuratori.com/blog_0031 (video linked from https://caseymuratori.com/talks)
- [V] Software reliability has gotten worse even as hardware has improved.
- [V] The OS is "no longer a product". It is a vehicle for platform holders' other business goals.
- [V] Proposal: hardware should consolidate on a few reasonable ISAs as a first step, with simpler and more sensible interface standards for hardware.
- [V] He concedes that shipping a stable hardware ISA costs more than shipping continually updated, buggy drivers. He argues the payoff for vendors and users would be large.
- [U] From the talk itself: a modern OS stack comes to about 30M lines, mostly drivers and layers, before your app runs. In the 1980s and 90s the PC and its BIOS-level standards let a program take over the machine. If SoCs exposed a standardized register-level interface for GPU, USB, storage, network and audio, an OS could shrink to a small library. An application could even ship its own minimal "OS" and boot it, much as old games did. The cost of drivers works like a tax that keeps new OSes from appearing.

**2. "Immediate-Mode Graphical User Interfaces" (2005)**
URL: https://caseymuratori.com/blog_0001
- [V] He developed the approach around 2002 for the Granny 3D viewer. Retained-mode GUIs have the same drawbacks that push graphics programmers away from retained-mode graphics APIs.
- [V] He coined "Single-path Immediate Mode GUI". In this style the UI is code that runs every frame and holds no mirrored widget-object state. Dear ImGui credits him.
- Takeaway for an OS: the UI toolkit should be a set of functions you call each frame. It should not be an object graph that the OS owns and that you keep in sync.

**3. "Semantic Compression" (2014-05-28)**
URL: https://caseymuratori.com/blog_0015
- [V] Write the specific case first and compress (generalize) only once a second real case appears: "make your code usable before you try to make it reusable".
- [V] He is against designing OOP hierarchies up front. Structure should emerge from working procedures.
- Takeaway for an SDK: grow APIs out of real uses. Do not design speculative frameworks.

**4. "Clean Code, Horrible Performance" (2023-02-28)**
URL: https://www.computerenhance.com/p/clean-code-horrible-performance
- [V] He criticizes four rules: prefer polymorphism to switch, don't know object internals, keep functions small, and do one thing. He considers DRY in its basic sense fine.
- [V] In his shape-area benchmark, the vtable version takes about 35 cycles per shape, a switch about 24 (about 1.5x faster), a table-driven version about 3.0 to 3.5 (about 10x), and AVX 20 to 25x. He says the measurement is not rigorous.

**5. "Performance Excuses Debunked" (2023-04-26)**
URL: https://www.computerenhance.com/p/performance-excuses-debunked
- [V] He rejects five excuses: "no need", "too small", "not worth it", "niche" and "hotspot". He cites performance rewrites at Facebook, Twitter and Uber, and argues that performance-aware programming can be learned in months.

**6. "Non-pessimization" / "Philosophies of Optimization" (Refterm lecture series, 2021)**
- [S] Non-pessimization means not making the CPU do work it does not need to do. He contrasts it with "fake optimization", meaning context-free rules. He argues it should make up most optimization effort. Secondary source: https://haskell.foundation/hs-opt-handbook.github.io/src/Preliminaries/philosophies_of_optimization.html
- Takeaway for an OS: every layer between the app and the hardware is a possible pessimization, so the default path should be the thin one.

**7. refterm and the Windows Terminal debate (June 2021)**
URLs: https://github.com/microsoft/terminal/issues/10362 and https://github.com/cmuratori/refterm
- [V] Issue #10362 was opened on 2021-06-08. With per-character colour escape codes, Windows Terminal ran about 40x slower than with single-colour output in his termbench.
- [V] Microsoft's Dustin Howett called Casey's proposed GPU glyph-cache renderer "an entire doctoral research project in performant terminal emulation". Microsoft then locked the thread.
- [V] **Mārtiņš Možeiko** profiled the problem in the same thread. Conhost's string formatting and allocations were the bottleneck, and disabling VT processing in a patched build gave about a 100x speedup.
- [V] The refterm README says it is "several orders of magnitude faster than Windows Terminal" while being "largely unoptimized". It is meant as a minimum bar: "If your terminal runs slower than refterm, that is not a good sign."
- [V] Uniscribe (Unicode shaping) and DirectWrite (glyph rasterization) are both very slow in the worst case. A simple glyph cache hides most of that cost.
- [V] Conhost comes within about 10% of a "fast pipe" if applications send large writes (`WriteFile`, or stdio with large buffers and binary mode).
- Lessons for an OS: the system text stack (shaping, rasterization, console pipe) must be fast in the worst case. Pipes must reward large writes. The renderer should batch by glyph atlas, not draw one call per attribute run. The cultural lesson is also part of the record: platform teams called a weekend-sized job "research", which is the kind of norm Handmade people want gone.

**8. Win32 and input latency**
- [S] In Handmade Hero forum replies, Casey advises not polling `GetCursorPos()` for latency-sensitive work. He notes that the display cursor is updated separately (as a hardware overlay) on most modern machines. Source: https://handmade.network/feed/627
- [U] On Handmade Hero he repeatedly praises Win32 for letting a program own its own loop: `PeekMessage` plus your own frame timing, `timeBeginPeriod`, raw `VirtualAlloc`, and the stable Win32 ABI that keeps old binaries running for decades. He complains about how hard it is to get reliable vsync and frame-timing information, and about audio latency (DirectSound, then WASAPI).
- [U] On Handmade Hero and in Q&A he dislikes installers, DLL hell and package managers, and holds up a single exe with no install step as the ideal. Handmade Hero ships as a platform exe plus a game DLL and builds with one `build.bat` unity build. No primary quote was found for the package-manager view specifically.

**9. Handmade Hero Day 021 "Loading Game Code Dynamically" (2014)**
URL (annotations): https://git.handmade.network/Annotation-Pushers/cinera_handmade.network/src/branch/master/cmuratori/hero/code/code021.hmml
- [S] Platform code and game code live in separate translation units. The game is a DLL that is passed function pointers in both directions. The platform loads and unloads the DLL at runtime. Persistent state moves into a `game_state` block owned by the platform, and the DLL file is not kept locked so it can be rebuilt while it runs.
- [U] Later episodes add live looped input record and playback by snapshotting one big fixed memory block. This depends on the game's memory being one contiguous block reserved at a fixed base address.

**10. "The Big OOPs: Anatomy of a Thirty-five-year Mistake" (Better Software Conference 2025)**
- [S] He traces OOP from Simula and Stroustrup to ECS, with examples such as Thief, and covers the pitfalls of encapsulation boundaries. Source: https://talkoverflow.substack.com/p/talkoverflow-14-highlights-from-better

### Jonathan Blow

**"Preventing the Collapse of Civilization" (DevGAMM Moscow, 2019-05-17)**
Video: https://www.youtube.com/watch?v=pW-SOdj4Kkk. Write-ups: https://robinrendle.com/notes/preventing-the-collapse-of-civilization/ and https://www.gcores.com/articles/110509
- [S] Technologies get lost when knowledge is not passed on (Byzantine "Greek fire", for example). Apollo went from nothing to the Moon in 12 years, and spaceflight has stagnated since.
- [S] Software gains mostly free-ride on hardware improvements. The number of people who understand the layers underneath is shrinking while dependence on software grows.
- [U] From the talk: robustness has collapsed (everyone accepts reboots and "have you tried turning it off and on"). He gives the "five-nines" counter-example. Abstraction layers mean nobody can debug the full stack. Simplification is the only fix, and deleting layers is how to start. He cites the Linux userspace and the mess of ld/glibc compatibility.
- [S] He said "debugging is terrible on Linux" and gdb is bad to use, and asked for a debugger built from scratch with a library-style API that IDEs can use. "Windows / Visual Studio is, itself, not particularly great". Kernels are generally stable and userspace is the problem. Source: https://mcvuk.com/?p=86627
- [S] Jai compile times: about 80k lines in roughly 1 to 1.5 s, with a target of 1M lines/s (second-hand: https://digitalmars.com/d/archives/digitalmars/D/Jai_compiles_80_000_lines_of_code_in_under_a_second_319451.html). [U] Jai builds are specified in the language itself (a metaprogram run at compile time) rather than with make, CMake or MSBuild. Games ship their own allocators, UI, asset formats and platform layers because OS and third-party layers are unreliable and slow.

### Ryan Fleury

**"Untangling Lifetimes: The Arena Allocator" (Digital Grove, 2022-09-23)**
URL: https://www.dgtlgrove.com/p/untangling-lifetimes-the-arena-allocator (formerly rfleury.com)
- [V] An arena is "a handle to which allocations are bound". The API is `ArenaAlloc/Release/Push/PushZero/Pop/SetPosBack/Clear/GetPos`. Lifetimes are grouped so that one clear frees everything, with no per-allocation `free`.
- [V] A growable arena reserves a huge contiguous virtual range (for example 64 GB through `VirtualAlloc`) and commits pages as the position advances. Address-space size varies by platform, and the Switch is small. The alternative is a chained-block arena.
- [V] Scratch arenas are thread-local. Callers pass in any conflicting arenas to avoid aliasing, and two scratch arenas cover arbitrarily deep call stacks.
- [V] He criticizes malloc/free (tangled lifetimes), RAII (hides complexity) and GC (pauses, leaks through references). He argues that freeing memory at process exit is often wasted work.
- Also: "Enter the Arena" talk, Handmade Boston 2023 (https://handmadecities.com/media/boston-2023/enter-the-arena/) [S].

**UI series (Digital Grove)**
- [S] An immediate-mode UI series in which retained mode "always [felt] like I was pushing sand around". [U] Features: a per-frame widget tree with keys and caching across frames, an autolayout pass, and animation driven by cached state. The RAD Debugger UI is built this way.

**RAD Debugger (Epic Games, open source, MIT)**
URL: https://github.com/EpicGamesExt/raddebugger
- [S] It is a native, user-mode, multi-process graphical debugger, in alpha, currently for Windows x64 with PDB, with Linux and DWARF planned. It ships with the RAD Linker, an in-progress drop-in replacement for the MSVC linker. It converts PDB and DWARF to its own RDI debug-info format for speed.
- [S] The codebase is a DAG of layers. Each folder is a layer with a short prefix (`D_`, `CTRL_`, `RD_`, `PDB_`, `DW_`…), and the `lib_*` folders are standalone libraries with no dependencies. [U] The lowest layers are `base` and `os`, with `render`, `font`, `ui` and `metagen` (a code generator) above them.
- [S] BSC 2025 talk "Cracking the Code: Realtime Debugger Visualization Architecture" covers visualization pipelines, caching, and visualizing non-text data such as geometry.

### Sebastian Aaltonen

**"No Graphics API" (blog, Dec 16, likely 2025 because it cites 2025 developments)**
URL: https://www.sebastianaaltonen.com/blog/no-graphics-api
- [V] PSOs shrink to the state that affects shader microcode (topology, formats, sample count, alpha-to-coverage). Blend and depth-stencil become separate small objects.
- [V] Descriptor sets, root signatures and bind groups are replaced by **one 64-bit root pointer per draw/dispatch** to a user struct. Textures are 32-bit indices into one global descriptor heap that CPU and GPU can both write.
- [V] Vertex buffers and layouts are replaced by raw pointers. Shaders get native 64-bit pointers.
- [V] Memory is CUDA-style `gpuMalloc` returning CPU-mapped GPU memory, plus GPU-only and CPU-cached readback types. Allocation is decoupled from resource creation.
- [V] Barriers are stage-to-stage plus a few hazard flags, with no image layouts. Sync uses 64-bit timeline counters in GPU memory instead of fences and semaphores. Command recording is transient and rendering is dynamic (no render pass objects). Geometry and tessellation stages are dropped in favour of compute and mesh shaders.
- [S] The follow-up NoGraphicsAPI library (MIT, September 2026) wraps Vulkan 1.4 (BDA, descriptor heap, unified image layouts). It goes with his SIGGRAPH 2026 talk. Source: https://cgworld.jp/flashnews/01-202610-NoGraphicsAPI.html

### Ginger Bill (Odin)

**"Pragmatism in Programming Proverbs" (2020-05-31)**
URL: https://gingerbill.org/article/2020/05/31/progamming-pragmatist-proverbs
- [S] Programs are tools for solving problems. Solve the specific problem you have, not a general one. Start from purpose.
- [S] "Marketing the Odin Programming Language is Weird" (2024-09-08, https://www.gingerbill.org/article/2024/09/08/odin-weird-to-market/): Odin has no killer feature, and "there are no solutions, only trade-offs".
- [S] He has publicly criticized package managers as "automated dependency hell" (video summary: "Why LSPs AND Package Managers Are Bad"). [U] Odin ships "vendor" libraries in the compiler distribution instead of using a package manager. It has an implicit `context` allocator (arena-friendly) and builds with one command from a directory, with no build system.
- [S] BSC 2025 talk "Tools of the Trade" (https://bsc2025.gingerbill.org/).

### Vjekoslav Krajačić: File Pilot
URLs: https://filepilot.tech/about and https://windowslatest.com/2025/02/24/hands-on-with-file-pilot-a-new-alternative-to-windows-11s-file-explorer
- [S] A Windows Explorer replacement built by one developer over about 3 years, with a public beta in February 2025. The installer is about 2 MB. Folders open instantly and search is instant. It is sold as perpetual access with no subscription.
- [S] BSC 2025 talk "File Pilot: Inside the Engine": a layered architecture, arena memory management, and async multithreaded directory enumeration.
- Lesson: a filesystem API has to allow bulk, asynchronous metadata enumeration so that a 2 MB app can beat the shell.

### RemedyBG
- [U] RemedyBG is a standalone Windows debugger by George Menhorn, sold on itch.io, and widely used in the Handmade community. It is a small exe that starts instantly, as a counter-example to Visual Studio's startup time. It is evidence that a debugger can be an independent small tool if the OS debug API is good.

### Allen Webster (4coder, Mr4th)
- [S] He built 4coder, a customizable code editor developed on stream, and works at RAD/Epic. Handmade Network podcast episode on 4coder architecture and "a better future of computing": https://handmade.network/podcast/ep/14a5407e-5f73-4c59-a422-44c4ece6a1bf
- [S] 4coder blog posts on cutting passive per-frame CPU use with a better file tracker: https://4coder.handmade.network/blog
- [U] Mr4th streams and writing on OS design: no primary source found. Treat any specific "Mr4th OS design" claims as unverified.

### Mārtiņš Možeiko
- [V] His profiling in Terminal issue #10362 found conhost formatting and allocations to be the bottleneck, and a patched build ran about 100x faster.
- [U] He is a prolific Handmade forum answerer on Win32/Linux platform details, DirectX/GL interop and minimal-CRT builds (no C runtime, `/NODEFAULTLIB`). These posts are widely cited.

### Abner Coimbre (Handmade Seattle / Handmade Cities)
- [S] He founded the Handmade Seattle conference and later Handmade Cities, which hosts talks such as Fleury's "Enter the Arena" (Boston 2023).
- [U] His framing is that "Handmade" means software built with understanding of the whole stack, by small teams, as a reaction to the bloat in modern development.

### Handmade Network: manifesto and jams
- [V] Manifesto (https://handmade.network/manifesto): modern software is slow, bloated, hard to compile and drains batteries. It blames rewriting without measuring, piling up dependencies, and abstractions few understand. Its remedy is learning how computers actually work.
- [S] Wheel Reinvention Jam (2021 onward, https://handmade.network/jam/2023): rebuild a program that frustrates you, from scratch, in a week. Casey supplied the name, from "why reinvent the wheel?" in Handmade Hero episode 1.
- [S] The Visibility Jam (2023 and 2024, for example July 19 to 21, 2024) produced tools for "seeing" data and one's own program. It was later merged into an "X-Ray Jam" that combined visibility and learning. Source: https://handmade.network/blog/p/9025-join_us_next_month_for_the_x-ray_jam%2521

### Others
- **Eskil Steenberg**, BSC 2025, "You Should Finish Your Software" [S]: stabilize APIs and ship. [U] His C-only, minimal-dependency style and his "How I program C" talk.
- **Andrew Kelley (Zig)** [U]: `zig cc` as a drop-in cross-compiler that bundles libc headers for many targets. Zig avoids hidden allocations (allocators passed explicitly) and has no hidden control flow. He has argued that software dependencies and libc ABI pain are fixable at the toolchain level. No primary source was fetched.
- **Demetri Spanos** [U]: appears on Handmade-adjacent podcasts and streams talking about first-principles computing and education. No source was found, so nothing specific is attributed here.
- **Wookash podcast (Łukasz Ściga)** [S]: long-form interviews with Handmade-circle people (Fleury, Inigo Quilez, Daniel Lemire and others). Listings: https://creators.spotify.com/pod/profile/lukasz-sciga/ . I did not verify specific OS claims from episodes.
- Note: the "Better Software Conference" in this circle is the Handmade-adjacent conference with the Casey, Fleury, File Pilot and gingerBill talks in 2025. It is not the unrelated Italian "BetterSoftware" conference.

---

## Part 2: Recurring asks, mapped to sources

| Ask | Who / where | Confidence |
|---|---|---|
| Instant startup, tiny binaries | refterm, File Pilot, RemedyBG, RAD Debugger | S/V |
| No installers, single-file apps | Handmade Hero build, Casey Q&A, gingerBill on package managers | U/S |
| Fast bulk and async file metadata | File Pilot talk, 4coder file tracker | S |
| Fast worst-case text and console | refterm, #10362 | V |
| Input-to-photon latency, cursor overlay, frame pacing | Casey HH forum, HH streams | S/U |
| Debugger as a first-class citizen | Blow, Fleury RAD Debugger | S |
| Hot reload via DLL swap, fixed-base memory | HH Day 021 | S |
| Reserve/commit virtual memory, arenas | Fleury, HH | V |
| App owns its main loop, no framework | HH platform layer, Casey on IMGUI | U/V |
| Stable ABI | Casey on Win32 longevity; Blow on Linux userspace | U/S |
| Simple build, unity build, fast compile | HH build.bat, Jai, Odin | S/U |
| Small dependency trees | Manifesto, gingerBill | V/S |
| Visibility into the system | Visibility Jam, RAD Debugger visualizers | S |
| Standardized hardware interface | Thirty-Million-Line Problem | V |
| Thin GPU API | Aaltonen | V |

---

## Part 3: Design principles for Todhchai derived from Handmade discussions

1. **The platform layer is a library the app calls, never a framework that calls the app.** The app owns `main` and its loop. There are no mandatory delegates, run loops, lifecycle callbacks or "main thread" ownership by the OS. Events arrive as a queue the app drains whenever it chooses (`poll` or `wait-with-deadline`), from any thread that holds the handle. (Handmade Hero platform layer, IMGUI.)

2. **The memory API exposes reserve / commit / decommit / release / protect directly, with an optional fixed base address.** Hand Zircon-style VMARs/VMOs to apps as plain functions. A 64 GB reserve should be cheap. Ship an arena (with scratch arenas) as the *default* SDK allocator and make malloc the opt-in. A fixed-base mapping enables Handmade Hero-style state snapshots and record/playback. (Fleury, HH.)

3. **Debugger attach, hot reload and record/replay are platform services.** Provide a documented, stable, *library-style* debug API (process control, memory read/write, threads, breakpoints, exceptions) so third-party debuggers like RemedyBG, RAD Debugger or a game's own can be first-class. Provide an SDK pattern plus OS support for swapping a code module while the process stays alive. Unlike Windows, do not lock loaded module files. Fixed-address state blocks make the swap safe. (Blow, Fleury, HH Day 021.)

4. **Use one debug-info format that is fast to load, and make symbols always findable.** RAD Debugger converts PDB and DWARF into RDI because the standard formats are too slow. Todhchai can pick a fast, indexable format (or adopt RDI, which is MIT) as the native one from day one.

5. **Apps are single files, and installing one means copying it.** There are no installers, registries or system-wide package manager for apps. An app is one bundle/exe that carries its own dependencies, with optional user-scoped data directories. Removing the file uninstalls the app. The OS keeps a stable, versioned system ABI so bundled binaries keep working for decades, as Win32 did. (Casey, gingerBill [U/S].)

6. **Keep the system ABI stable, small and C-callable.** The kernel and platform ABI should be plain functions and structs, versioned, with no ABI coupling to Swift generics or runtime metadata. Swift is the implementation language, but the published ABI must be callable from C, Odin, Zig, Jai and Rust without a Swift runtime. This matters for the indie and AAA audience. (Blow's Linux userspace complaint, Casey on Win32.)

7. **Make I/O asynchronous and batched by default, with bulk metadata enumeration.** Use one completion-queue model (io_uring-like, on Zircon ports) for files, sockets, pipes and devices. "List directory with all stat fields" must be one batched call that streams results, and unbuffered or direct I/O must be available for asset streaming. File change notification should be precise and cheap, unlike 4coder's polling cost. (File Pilot, 4coder.)

8. **Pipes and consoles reward large writes and never pessimize.** Byte streams carry no per-write formatting cost. The terminal and text stack is built refterm-style, with a GPU glyph atlas, a glyph cache and batched draws. Worst-case Unicode shaping and rasterization should be fast. Publish a termbench-style benchmark as an acceptance test. (refterm, #10362, Možeiko.)

9. **Treat input-to-photon latency as a measured, published OS metric.** Provide raw input with hardware timestamps, a high-rate (≥1 kHz) path, and a hardware cursor plane that the compositor uses. Give apps direct flip / fullscreen-exclusive-equivalent presentation that bypasses composition. Expose presentation feedback (when a frame actually hit scanout) and real vsync and VRR timing. Ship a latency-measurement tool in the box. (Casey [S/U].)

10. **Give the app control of frame pacing.** Provide APIs for "present at time T", querying the next vblank, and high-resolution sleep/wait-until with sub-millisecond precision (no `timeBeginPeriod` hacks). Let the app choose its swap policy (mailbox, FIFO, immediate).

11. **Make the GPU API thin, following "No Graphics API".** Offer one native low-level API: `gpuMalloc` returning mapped pointers, one global descriptor heap with 32-bit indices, one root pointer per draw, stage-level barriers, 64-bit timeline counters, and transient command buffers with dynamic rendering. Put Vulkan and Metal compatibility layers on top for porting. Skip legacy stages. (Aaltonen.)

12. **Ship UI as an immediate-mode library, not an OS object tree.** The system UI kit is an IMGUI-style library (Fleury and Dear ImGui style, with keyed caching and autolayout) that apps call each frame. A retained-mode toolkit can be an optional library above it, never the only path. The OS shell itself should be built with the same public library ("eat your own platform"). (Casey 2005, Fleury.)

13. **Visibility: the system shows what it is doing.** Every process gets a live, inspectable view of its own threads, memory maps (reserve vs commit), handles, I/O queues and GPU queues. Provide a system-wide timeline profiler (ETW-like but simple), cheap to enable, readable as plain data. Wait reasons ("why is this thread blocked?") should be first-class. This is the OS answer to the Visibility and X-Ray Jams.

14. **Builds are one command.** The SDK compiles a whole app with one command (unity-build friendly), with no mandatory project files or build-system DSL. SDK headers and modules are self-contained, and compiling "hello window" should take well under a second. (HH build.bat, Jai, Odin.)

15. **Keep dependency trees small, by policy.** The base system has a published dependency graph for every component, a line-count budget, and a rule against pulling in large third-party stacks for core services. Track total lines in the boot path as a metric, which directly answers the Thirty-Million-Line problem.

16. **Use layered, DAG-structured system code.** Structure the OS userland like the RAD Debugger codebase: `base → os → render/font → ui → app`, with each layer a short-prefixed module and no cycles. Each layer is usable alone (`lib_*` style), so a game can take the `os` layer without the UI.

17. **The user owns the machine.** No telemetry by default, no forced updates or reboots, no account requirement, and no app store gate. Updates are explicit, atomic and reversible. Root of trust is the user's keys. (Casey: the OS as a "vehicle for platform holders' business goals" [V].)

18. **Expose hardware directly, with capability gating.** A privileged app (a game in exclusive mode, a profiler) can get Zircon handles to the GPU queue, audio DMA buffer, input device rings and performance counters, all gated by capabilities rather than hidden behind services. Audio offers a low-latency exclusive ring-buffer path.

19. **Drivers are small, user-space and standard-first.** Favour standard hardware interfaces (NVMe, xHCI, HDA, virtio, and UEFI GOP as a fallback) over vendor stacks. Pick a narrow, supported hardware matrix, as consoles do, and publish it. This is the practical version of the standardized-ISA argument.

20. **Instant startup is an acceptance criterion.** Boot to a usable desktop and cold-launch system apps within budgets checked in CI (for example, an app visible in under 100 ms). Benchmarks such as refterm, File Pilot folder-open and debugger attach count as release-blocking tests.

---

## Part 4: Disagreements and impractical ideas

- **Standardized hardware ISA (Casey)** is economically unlikely. GPU vendors compete on exactly the interfaces it would freeze, and Casey himself concedes the cost [V]. A small OS cannot force it. The realistic approach is a narrow, console-like supported hardware list plus standard device classes (principle 19). GPU support stays the hard problem: without vendor cooperation, Todhchai may have to rely on existing open drivers (Mesa-class stacks, which are themselves millions of lines). That partly reintroduces the 30M lines.
- **"Apps bring their own OS"** conflicts with multitasking, security isolation and a desktop shell. Capability-gated direct access (principle 18) is the compromise.
- **Single-file apps vs security updates.** If every app bundles its dependencies, a vulnerable TLS library has to be patched app by app. The community mostly accepts this cost, while distro maintainers strongly disagree. Mitigation: a small, stable OS-provided crypto/TLS ABI.
- **Arena-everything vs general-purpose allocation.** Fleury's arenas suit frame and request lifetimes. Long-lived, graph-shaped app data (editors, browsers) still needs pools or general heaps, and Fleury layers pools on arenas [V]. Swift's ARC model is fundamentally at odds with arena-first design, which is a real tension for Todhchai's language choice. The SDK will need non-ARC, unsafe-pointer, arena-based paths that are idiomatic rather than second-class.
- **Clean Code criticism.** Many engineers dispute that Casey's micro-benchmark generalizes. He says himself that the measurement is not rigorous [V]. The robust takeaway is non-pessimizing defaults, not a ban on abstraction.
- **IMGUI for everything.** Accessibility (screen readers need a semantic tree), IME/text input, and power use (redrawing every frame) are known weak points. An immediate-mode API can still emit a retained accessibility tree as a side output, and that has to be designed in from the start.
- **Microsoft's "doctoral research" position** was wrong on the core performance claim. Later Windows Terminal versions adopted an atlas renderer [U]. Their real points about full Unicode, ClearType and edge cases are legitimate scope costs.
- **Blow's civilization thesis** is criticized for focusing on code and neglecting organizational coordination [S, gcores]. Some think the "collapse" framing is overstated [S, Shamus Young].
- **Package managers.** gingerBill and Casey oppose them, while Zig's Kelley built one into the toolchain (`build.zig.zon`) [U]. Even within the circle, the line falls between "no package manager" and "content-addressed, vendored-by-default package manager".
- **Linux as the base.** Blow says the kernel is fine and userspace is the problem [S]. That raises the question of whether a new kernel is needed at all. Todhchai's Zircon-style choice is defensible for capabilities and driver isolation, but the Handmade asks are mostly userland and API asks.

---

## Part 5: Things to verify before citing
- Exact claims in the Thirty-Million-Line video: line counts, the "boot your own OS" thought experiment, and USB/GPU examples.
- Casey's statements on package managers, installers and DLL hell (no primary quote found).
- Blow's talk specifics beyond the secondary summaries.
- Mr4th/Allen Webster OS-design writing, and Demetri Spanos's views (no sources found).
- RemedyBG authorship details, Andrew Kelley positions, and the RAD Debugger `base/os/ui/metagen` layer names.
- The "No Graphics API" publication year (most likely 2025-12-16).
