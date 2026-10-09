# NeoDarwin API study: digest for Todhchai

Source tree: `/home/jkane/Projects/OS/NeoDarwin-api-study/` (all paths below are relative to it). Study dated 2026-09-27/28. The NeoDarwin toolkit charter it feeds (`NeoDarwin/docs/desktop/toolkit-charter.md`, "14 principles P1–P14") is **not on this machine**; its content is only visible through `prototypes/ndtk/API.md` and `reports/s7-prototypes.md`.

---

## 1. Method, and how much to trust it

**What was done** (`DESIGN.md` §3, `reports/STATUS.md`):
- A 197-concept taxonomy in 12 domains (WIN, EVT, INP, PRS, GPU, CMP, AUD, TIM, THR, MEM, IO, PKG), seeded from SDL3 backend hooks, DXVK/vkd3d, MoltenVK, hipify, Wine and wgpu (`taxonomy/concepts.yaml`, `reports/taxonomy-v2.md`).
- About 153k platform symbols from 14 modern platform tables (Win32, DXGI/D3D12, Vulkan/GL/EGL/CL, Wayland, Linux UAPI, macOS, Haiku, Plan 9, CUDA/HIP/SYCL), plus 14 heritage tables (Amiga via AROS, Atari TOS/GEM, 12 consoles via open SDKs). Every symbol is mapped to a concept.
- A lexical call extractor over 44 open projects (Tier A deep: SDL, Godot, Blender, wgpu, Wine, DXVK, vkd3d, llama.cpp, Zed, bevy, etc.; Tier B wide). 193k usage hits. Validated against clang on 39 files: **92.6% precision, 96.0% recall** (`reports/s2-validation.md`).
- Backend weight and 3-year churn (commits per kLOC), 9.3k tagged workaround comments, 9.1k perf commits.
- Friction admitted only with **read code evidence from at least 3 independent projects** (`DESIGN.md` §3.6). 30 entries admitted.
- S7: five programs written three ways (candidate API "ndtk" via a macOS shim, SDL3, native AppKit/Metal), measured on a 60 Hz Mac.

**Trust levels:**
- **High:** the friction entries (each one cites `file:line` code that was read), the Q2 wrapper comparison (headers read by hand), and the S7 measurements. S7 numbers are macOS-host baselines only, at 60 Hz (`reports/s7-prototypes.md` intro).
- **Medium:** concept usage counts. They are **ordinal, not exact** (`reports/STATUS.md` "Known limitations"). Known pollution: generic names (`GetState`, `QueryVersion`, `MouseButton`) inflate some concepts; INP.pen is "mostly an artifact"; generated protocol headers are counted as use; CRLF files mine to line 1 (`reports/friction-triage-system.md` §5, `reports/friction-triage-graphics.md` §6).
- **Lower:** the Q5 effort estimates. Wayland server size (10–20k lines), the epoll shim and x86 emulation were never measured (`reports/q5-compat.md` §8). The heritage tier-H extraction skipped `examples/` dirs, so the console minimal-program counts were taken by hand (`platforms/consoles-retro-SUMMARY.md` §5).
- **Blind spots:** no AAA streaming engine is in the corpus, and DirectStorage is absent from the Windows tables. So GPU-direct I/O was "not confirmed" for lack of data, not for lack of need (`reports/friction-triage-graphics.md` §3). Issue trackers were never mined (S4). There is no mobile and no developer survey.

---

## 2. Q1: the common core

Source: `reports/concept-matrix.md`, `reports/convergence-raw.md`. Columns: os = OS families offering the concept (of 5), proj = corpus projects using it (of 44), hits = call hits.

**Converged everywhere and heavily used.** This is the candidate core API surface:

| Area | Concepts (os / proj / hits) |
|---|---|
| Loop | EVT.dispatch 5/32/3361 · EVT.fd 5/31/492 · EVT.lifecycle 4/26/1167 · EVT.runloop 5/22/735 · EVT.mainthread 5/23/181 · EVT.user (post) 4/21/323 · EVT.pump 5/20 · EVT.wait 4/17 |
| Window | WIN.window.create 5/31/1718 · geometry 5/28/1738 · destroy 5/27 · focus 4/27 · title 5/25 · show 5/24 · decorations 4/22 · cursor 5/24/1708 · display.enumerate 4/28/3573 · display.scale 3/25/878 · surface.native 4/30 · surface.software 5/30 · subsurface 5/23 · clipboard 5/20/2245 · menu 4/20 · draw2d 5/21 · font 5/19 |
| Input | INP.key.event 5/28/1832 · key.map 5/22/3209 · pointer.event 5/25/2537 · wheel 5/22 · pointer.lock 5/21/623 · text.ime 5/20/1862 · text.input 4/18 · gamepad.state 4/12/1037 |
| Present | PRS.swapchain.create 3/28/2443 · PRS.present 5/27/559 · acquire 3/24 · damage 4/21 · timing.pacing 4/20/403 · hdr 3/19 · timing.feedback 3/10/207 |
| GPU | device.features 3/34/4025 · resource.texture 3/32/9368 · device.create 3/32 · sync.fence 3/31 · resource.buffer 31/4247 · binding 30/7285 · cmd.record 30 · pipeline.create 29/6087 · renderpass 29 · mem.alloc/map 26–28 · interop.external 4/23/1641 |
| Time/threads/memory | TIM.monotonic 5/30 · TIM.sleep 5/21 · TIM.timer 5/15 · THR.create 5/31 · mutex 5/23 · condvar 5/25 · MEM.heap 29 · MEM.virtual.reserve 5/20 · MEM.protect 5/20 |
| I/O, packaging | IO.file.sync 4/30/3423 · IO.fs.ops 4/28 · PKG.dynload 4/35/1755 (the most widely used concept of all; see F-219) |
| Audio | AUD.stream.open 5/10/1272 · stream.push 5/13 · device.enumerate 4/10 · format 4/8/1235 · stream.callback 4/7 |

**Notable shapes in the counts:**
- Push audio (13 projects) is used more than callback audio (7). AUD.rtthread is used in only 4 projects.
- THR.channel is offered by all 5 OS families and used by 0 projects. THR.hetero is used by only 3. IO.file.async 14 vs IO.file.sync 30. IO.gpu.direct 0.
- Concepts that only exist on 1–2 platforms but are used widely, i.e. a platform gap the app fills itself: EVT.wake (2 OS, 12 projects), TIM.resolution (Windows/Linux knobs, 13 projects), THR.pool, WIN.window.stacking (`reports/convergence-raw.md`).
- Heritage density (`reports/heritage.md` §2): calls per concept are Atari 11, Amiga 14, Haiku 22, macOS 28, Windows 70, Linux 102. WIN.window.create takes 3 calls on Amiga, 2 on Haiku, 26 on Windows and 34 on X11. Breadth of concepts is real progress; duplicated generations of APIs within one concept are not.

---

## 3. Q2: the productive wrapper shapes

Source: `reports/q2-shapes.md` §3 (C1–C13) and §7 (R1–R14). Libraries compared: SDL3, GLFW, sokol, raylib, winit, wgpu, ImGui, egui, bevy, Godot, gpui (Zed), JUCE, LÖVE, against `libintuition` (the Amiga-style NeoDarwin candidate).

**API size** (§1.2): GLFW 151 functions and sokol_app 56 cover the same window, input and frame concepts as SDL's 1,316; SDL's size is breadth, not depth. GLFW marks 93 functions "main thread only", SDL has 273 such doc lines, and libintuition has 38 functions.

**Convergent shapes, each in at least 3 independent layers:**
1. **C1:** one fixed-size tagged event record with a small-integer window id. SDL uses a 128-byte union with a compile-time assert; wsys a 32-byte `Deskevent`. Variable payloads (text, IME, drop) are borrowed and valid until the next pump. No object per event (Godot) and no callback per kind (GLFW).
2. **C2:** one loop with wait and poll modes plus a deadline (winit `WaitUntil`, egui `repaint_after`, bevy `reactive`/`continuous` presets).
3. **C3:** an inverted callback main (`init/iterate/event/quit`) appears only where the platform forces it (iOS, web, modal loops). App-owned loops survive wherever they can. Only the callback form gets live resize in SDL.
4. **C4:** re-entering the frame from inside the OS modal loop. The identical `SetTimer(USER_TIMER_MINIMUM)` hack is in SDL, sokol, Godot and gpui; 9 of 13 layers reference modal markers.
5. **C5:** a main-thread proxy plus a coalesced, payload-free wake (SDL `RunOnMainThread`, winit proxy, JUCE `callAsync`).
6. **C6:** a coalesced "redraw requested" signal paced by a per-output clock. gpui and JUCE each run their own display links. Pacing lives in the frame callback, not in `present()`.
7. **C7:** resize and scale as events, with logical and physical size separated. 12 of 14 layers touch scale.
8. **C8:** GPU handoff through a native-handle bag (raw-window-handle, SDL properties). The swapchain is reduced to configure/acquire/present plus **one latency number** (wgpu `desired_maximum_frame_latency`).
9. **C9:** **index + generation handles** at every boundary. sokol, Godot RID, bevy Entity and gpui EntityId reached the same bit layout independently. Refcounting is fine inside a process.
10. **C10:** two-tier audio: a stream (pull callback plus push, with conversion) and voices on a mixer.
11. **C11:** styling owned by a theme, not the widget; retained state keyed by id plus per-frame scratch arenas (gpui 1 MiB arena, raddebugger `build_arenas[2]`); flex layout with separate measure and arrange passes. egui's single pass is its documented weakness.
12. **C12:** C layers take a user allocator; sokol adds fixed pools and per-frame budgets.
13. **C13:** no exceptions across the API (`bool` plus thread-local error at the C ABI). Resize is a state, not an error (wgpu's `Outdated` is the anti-pattern).

**Recommendations (R1–R14).** Each is directly reusable:
- **Events:** a fixed versioned record with a 64-bit monotonic ns timestamp, a window handle and a payload span. Widen the 32-bit subscription mask before v1: 30 of 32 types are already planned.
- **Loop:** the app owns it and it waits once: `wait(until:leeway:)` plus `poll()` over one kernel wait. Frame, timers, audio-contract changes and I/O completions are all events in that wait. Ship `reactive` and `continuous` presets, and an SDL3-shaped callback driver only as a thin layer (R3).
- **Threads:** no thread affinity. Provide `post(to: loop)` plus a coalesced `wake()` (R4).
- **Frames:** the compositor owns the frame clock. A coalesced `requestFrame()`; the frame event carries the next target time and the previous frame's actual present time; `latency n`; hidden windows are throttled, never starved (R5).
- **Units and surfaces:** logical units, with resize and scale in one ordered event carrying a configuration `seq`, and presents tagged with that `seq` (R6). One surface object handed to Vulkan WSI or wgpu (R7).
- **Handles and memory:** generation handles at the C ABI; an invalid handle is a diagnosed no-op (R8). Two memories: a per-frame arena and a slot-table node store (R9).
- **Audio:** the toolkit owns two-tier audio, with no lock on the callback path (R10).
- **UI:** retained widgets with theme-owned style, plus an immediate-mode layer on top (R11).
- **Errors and modality:** typed throws in Swift, codes at the C ABI, no fatal defaults (R12). No modal API anywhere (R13).
- **R14:** measure the minimal program against the Amiga/Switch bar of about 12–13 calls.
- **Audience note** (§4): raylib's polled `IsKeyPressed` state is right for beginners **as a convenience layer over the record queue**, not as the base API.

---

## 4. Friction register: all 30 entries

Owner abbreviations: **TK** toolkit · **WS** window system fast path (`wsys`) · **GPU** P7 GPU/compute stack · **K** kernel scheduler/VM (or kernel HID) · **PKG** build/packaging. Files are `friction/F-NNN-*.md`; triage is in `reports/friction-triage-{graphics,system}.md`. All "Prototype check" fields still say "pending (S7)"; S7 results are in §7 below.

### Graphics, presentation and compute (F-101 to F-111)

| ID | Title | Problem (one line) | Proposed fix | Owner |
|---|---|---|---|---|
| F-101 | Present timing unknowable | Apps can't learn when a frame hit the glass, so media and browser code writes per-platform estimators; engines ignore it entirely | Frame event carries present seq, scanout timestamp, refresh interval and flags, push-based like `wp_presentation`; optional target time on `present`; expose `VK_KHR_present_id2`, `present_wait2` and `VK_EXT_present_timing` on top of it | WS (+GPU) |
| F-102 | Pacing source and queue depth differ | Every platform paces differently; Wayland FIFO freezes hidden windows (SDL, Zed and Blender each hit it) | One per-output frame clock delivered as an event, never a blocking driver call; a `latency n` queue bound where present fails fast; throttled (not withheld) clock when hidden | WS |
| F-103 | Pipeline compile at first use | PSO compile stutter; caches rejected after driver updates; every engine builds background compile plus an ubershader | GPL or shader objects plus dynamic state as a guaranteed baseline; a system pipeline-cache service keyed by (app, shader hash, driver build); install-time warming; a compile-status query | GPU (+PKG) |
| F-104 | 3–5 graphics backends per engine | 12 projects have ≥3 backends; 17–31% of backend commits touch several at once; features cut to the intersection | No new native API; Vulkan is the only native API, with a published profile; WebGPU as the portable layer; DXVK/vkd3d for D3D | GPU |
| F-105 | Per-vendor compute backends | CUDA/HIP/SYCL/Metal/OpenCL/Vulkan; llama.cpp has 17 backends that drift apart (4% cross-backend commits) | Vulkan compute guaranteed (coop-matrix, subgroups, 8/16-bit, BDA) plus a CUDA/HIP-shaped host API (streams, events, device pointers, graphs) | GPU |
| F-106 | Every engine rebuilds barrier/layout tracking | Render graphs and state trackers are among the most churned code (wgpu 3.7k lines, Blender 4.3k, Godot 3.9k); shipped games omit barriers | Require `VK_KHR_unified_image_layouts`; ship a system resource-state tracker and render-graph library; sync validation on by default in the dev toolchain | GPU |
| F-107 | Cross-API/process/compositor buffer sharing | IOSurface vs dma-buf vs NT handles; per-API-pair import calls; browsers and media players build huge layers (Chromium SharedImage about 42k lines) | One GPU buffer object everywhere: memory object + format/modifier + timeline fence; mandatory device-UUID query; a compositor surface kind that takes buffer + fence for zero-copy present | GPU (+WS) |
| F-108 | Host memory as GPU memory | Wrapping mmap'd files or process memory without a copy needs a different call per stack with different alignment and pinning rules | A VM call: task address range → GPU buffer object, page alignment, IOMMU-backed; `external_memory_host` with page-size alignment; one "is coherent UMA" query | K |
| F-109 | GPU budget guessed | Budgets are heuristics not tied to OS memory pressure; engines run their own residency managers and watermarks | Kernel accounts GPU buffers to the task footprint; one per-task budget and one pressure notification for CPU+GPU; map Vulkan priority to purgeability and eviction order | K |
| F-110 | Per-vendor driver quirk tables | Every GPU codebase keeps vendor/device/driver-version quirk tables, rediscovering the same bugs | CTS plus a platform conformance suite gate every driver; a published machine-readable known-issues DB; drivers update with the OS | GPU |
| F-111 | Shader IR and binding translation | SPIR-V/DXIL/MSL/GLSL/WGSL plus 4 binding models; translators are big components | SPIR-V is the only native IR; one published binding model; a system offline shader-toolchain package; WGSL/HLSL accepted only above the driver | GPU (+PKG) |

### System side (F-201 to F-219); tier 1 = strongest charter impact

| ID | Title | Problem | Proposed fix | Owner |
|---|---|---|---|---|
| F-201 (T1) | Platform owns the UI thread and its wait | AppKit main thread, Win32 thread-affine HWNDs, single-queue Wayland/X sockets; engines run "platform threads" and marshal; wakes differ everywhere | No API tied to the first thread; per-window serialisation; one kernel wait over window events, app fds, a user wake and a timer deadline (requires readiness on window-protocol fids) | TK (+K readiness) |
| F-202 (T1) | Modal loops stall the app | Move/resize/menu/drag run nested OS loops; everyone adds the `WM_TIMER` hack; Wine fakes the loop | Normative rule: nothing runs a nested loop in the client; async dialogs; a `DS_INTERACTIVE` state bit; DE_RESIZE at most once per composited frame | WS (+TK rule) |
| F-203 (T2) | No precise deadline sleep | `timeBeginPeriod`, spin-sleep hybrids; nobody uses `mach_wait_until` or `clock_nanosleep(ABSTIME)` | One primitive: sleep until absolute deadline D with leeway L, with a published accuracy target (e.g. p99 < 100 µs); no resolution knob; coalescing only for background QoS | K (+TK) |
| F-204 (T2) | Threads can't state intent | Apps probe `cpuid`/sysfs for E-cores and disable throttling instead of describing work | One intent vocabulary: `interactive-frame`, `interactive`, `throughput` (gang on one core type), `background`, `realtime(period, computation, constraint)`; no raw priority or affinity; topology published as a file; window visibility lowers QoS automatically | K |
| F-205 (T1) | Per-output scale and topology | Windows has 4 DPI modes, X11 global Xft.dpi folklore, Wayland integer then fractional scale | The server picks one scale per window and sends `DE_SCALE` (rational n/120 plus seq); resize carries logical+pixel size; stable output names; `DE_OUTPUT` hotplug; one mode only | WS |
| F-206 (T1) | Negotiated geometry and popups | Async WM negotiation, ignored requests, popup placement re-implemented by SDL, winit and Wine | A ctl write returns after it is applied, with a seq; an anchored `popup` request (xdg_positioner semantics); explicit window kinds (toplevel/transient/popup/tooltip) | WS |
| F-207 (T1) | Custom titlebars and decoration ownership | Apps want content in the title bar but keep drag, snap, shadow and buttons; Win32 NCHITTEST, macOS private selectors, Wayland CSD | `flags -titlebar` gives the strip to the client; client declares `drag`/`gadget`/`nodrag` regions; the server keeps hit-testing; server-driven interactive move/resize | WS |
| F-208 (T1) | Live-resize content sync | Render thread and window geometry drift apart, giving stretched or black frames; Qt and Firefox go back to main-thread transactions | Every buffer carries the configuration `seq`; the server composites only against matching geometry (clipped/padded, never stretched); presents from any thread; GPU presents carry the seq | WS (+GPU) |
| F-209 (T2) | Implicit visibility | Hidden windows block FIFO swaps or waste frames; Firefox carries a 1,474-line occlusion tracker | Visibility state (`visible`/`partial`/`occluded`/`hidden`) computed by the server; present never blocks; frame event always delivered (throttled to e.g. 1 Hz when hidden) | WS |
| F-210 (T1) | Keyboard layout, modifiers, repeat | AltGr as fake Ctrl, Cmd eats key-up, no scancode on macOS, X11 pre-event modifier state | Key record: USB HID usage, modifier state after the event (L/R), unmodified rune under the active layout, server-generated flagged repeat, a keymap service plus `DE_KEYMAP`; toolkit does shortcut matching | WS (+TK) |
| F-211 (T1) | IME routing | IMEs need keys first, a caret rect and surrounding text; TSF/Cocoa synchronous callbacks | A per-window `ime` control file (enable, rect, purpose, surrounding); `DE_PREEDIT`/`DE_COMMIT`/`DE_DELETE_SURROUNDING`; the IME runs beside the compositor; pass-through keys flagged; a toolkit text-field adapter of about 50 lines | WS (+TK) |
| F-212 (T2) | Pen input | Wintab vs Ink; X11 classifies pens by device-name substrings; proximity missing on macOS | One pointer stream with pen fields, `DE_PROXIMITY` with tool type taken from HID Digitizer usages; no parallel emulation stream | WS (+K HID) |
| F-213 (T1) | Relative motion and pointer lock emulated by warping | macOS 250–500 ms warp freeze; Raw Input is a separate stream; Wayland had no warp | Server-side `pointer lock/confine/free/warp`, dropped and restored on focus; `DE_MOTION` with unaccelerated and accelerated deltas; `DMF_WARPED` flag | WS |
| F-214 (T2) | Gamepads bypass the platform | SDL's HIDAPI is 49.9 kLOC (more than SDL's 4 video backends combined, 61.9 kLOC); Godot vendored SDL just for pads | A kernel HID gamepad class with per-family drivers plus a controller DB as data; one enumeration path; `/n/desktop/gamepads/N` delivered to the focused window; thin SDL_Gamepad-shaped toolkit wrapper | K (+WS, TK) |
| F-215 (T1) | Real-time audio needs 3 mechanisms | MMCSS vs Mach time-constraint vs SCHED_FIFO/rtkit; Godot gives MMCSS to the wrong thread | Kernel admission test (period, computation, constraint → accept or refuse with a reason, as in Plan 9 EDF `admit`); unprivileged within a per-user budget; the toolkit audio stream creates the RT thread and exposes a workgroup; misses observable as text | K (+TK) |
| F-216 (T2) | No single audio stream contract | Latency spread over 4 CoreAudio properties, Pulse latency buggy, WASAPI fixed period | One versioned contract record (period, rate, summed end-to-end latency, device↔monotonic clock anchor, stable device id); changes arrive as events; the service follows the default device | TK (+audio service) |
| F-217 (T2) | Async asset I/O on one platform per project | io_uring/IoRing/overlapped each used on one OS; 28 projects use blocking reads; no one uses `dispatch_io` | One batched submission/completion ring as the I/O primitive, completion waitable in the one loop; per-request cache policy; the kernel absorbs alignment; toolkit "load these ranges" | K |
| F-218 (T3) | Address-space views and JIT W^X | Wine/Dolphin/RPCS3 each need reserve + aliased views + JIT with OS-specific recipes ("unmap and hope") | `reserve(size, align, [fixed])` → reservation object; atomic `map_view`/`unmap_view`; JIT allowed in reservations with a per-thread W^X toggle granted by manifest entitlement | K |
| F-219 (T1) | Every project builds its own loader | Godot generates 34 dlopen wrapper files (48k lines); SDL keeps SONAME tables; `GetProcAddress` per Win32 function | One versioned platform ABI declared in the package manifest; install-time solver; weak-link plus availability annotations checked statically; optional services reached through the namespace (absence is an open error) | PKG |

**Rejected or deferred** (`reports/friction-triage-graphics.md` §2, `-system.md` §2): device loss/TDR (deferred; "define a device-loss contract"), sparse/tiled resources, GPU query timestamps (never read), launch overhead, GPU video, IO.gpu.direct (no data), clipboard/DnD, cursor, gestures, keyboard grab, AUD.exclusive, large pages, bundle/sign.

**Ownership split:** WS 10, K 6 (+F-108/F-109 on the GPU side), TK 2, PKG 1, GPU 7. The window-system entries are the bulk, and they are cheap because NeoDarwin owns the compositor. The pattern to note: **Wayland is the most expensive backend in every project** (winewayland churns 4.6× Wine core; Chromium's ozone-wayland is 67k lines against 8k for X11), because a minimal core protocol pushes decorations, repeat, scale and configure handshakes onto clients (`reports/friction-triage-system.md` §4).

---

## 5. Q5: compatibility layers

Source: `reports/q5-compat.md`. Reach is out of 37 applicable Tier A+B projects.

**Ranking by reach per unit of marginal effort** (§4):

| # | Layer | Reach | New code | Notes |
|---|---|---|---|---|
| 1 | WebGPU packages (wgpu, Dawn) | 8 (3 hard deps: bevy, zed, egui) | ~30–100 lines of surface glue + packaging | conditional on Vulkan; no present timing (F-101 hurts) |
| 2 | GL/GLES/EGL via **Zink** | 7 GL-only + 11 fallbacks | 0 (Wayland EGL) to 1.2–3.3k for a native EGL platform; Haiku's EGL glue is 1,245 lines | needs the F-107 buffer object |
| 3 | **Vulkan via Mesa** + profile + WSI + CTS | **25** | WSI 0–4.7k; GPU uAPI glue 26k (**Fuchsia magma**) to 74k (FreeBSD linuxkpi) | the foundation for 1, 2, 7 and 8; profile floor = DXVK's (Vulkan 1.3 + 53 required features, BC compression, geometry shaders, robustness2, maintenance5/6) |
| 4 | Wayland "core+" (core + 16 extensions) | **23** | ~10–20k server side (estimate) + libwayland kqueue port | core = 108 requests/71 events; core+ adds 92/44 (fractional-scale, viewporter, decoration, activation, cursor-shape, pointer-constraints, relative-pointer, text-input-v3, primary-selection, xdg-output, idle-inhibit, toplevel-icon, linux-dmabuf, presentation-time, fifo, commit-timing) |
| 5 | POSIX + Linux shims (epoll/eventfd/memfd) | all 37; 3 headless run on it alone | a few k (unmeasured) | define your own target macro; don't pretend to be `__APPLE__` |
| 6 | SDL3: audio + HID now, native video later | 11 with SDL code, 3 depend on it | 1–2k lines; 5–13k with a native video backend (Haiku's is 3,025) | value is the SDL game catalogue outside the corpus; SDL_gpu has **1** corpus consumer |
| 7 | Wine + DXVK/vkd3d-proton | 5 (large outside) | Wine port, the F-218 VM API, x86 emulation on ARM64 | release 2+ |
| 8 | Compute: Vulkan compute → OpenCL → CUDA-shaped | 1 / +1 / potentially 4 | ~0 / moderate / research-scale (CUDA→SPIR-V device compiler + BLAS/DNN libraries) | use HIP names (MIT) to avoid the NVIDIA EULA |
| 9 | Metal | **0 unique** | 2,880 symbols + an MSL compiler | never |

**Key conclusions:**
- **Toolkit GPU API decision (§6):** expose Vulkan only as the interop seam (surface plus buffer-object import/export). The toolkit's drawing API is **WebGPU-shaped, concretely `webgpu.h` (Dawn), with SPIR-V input allowed**. No SDL_gpu clone: it is cut to the intersection of its backends, carries the main-thread rule, and runs for free on Vulkan anyway. On a single-backend OS, WebGPU can publish native Vulkan limits as a platform feature level. Size comparison: SDL_gpu 97 functions, `webgpu.h` 277, Vulkan 865 commands.
- **"Darwin-likeness buys little":** only 1.4% of macOS-path usage is libSystem-level; 96% is AppKit/CA, Metal and frameworks. There are 1,045 `__APPLE__` guard lines against 18 for `__MACH__` and 305 for `__linux__`. Porting cost is Linux-isms (epoll etc.), so new OSes should enter projects as a "Linux-like Unix" (§3 C8).
- **Minimum first release:** POSIX + shims, Wayland core+, Mesa Vulkan + profile, Zink, a PulseAudio-protocol audio door, SDL3, wgpu/Dawn. That gives **28/37 projects, or 32/37 with optional Xwayland**; the remaining 5 are the Wine stack (§7).
- Rules (§5): nothing sits beside Vulkan; GL, WebGPU, D3D and the toolkit GPU API all compile down to it; the Wayland door translates into native semantics, never the reverse; the compositor uses Vulkan directly.

---

## 6. Q6: heritage lessons

Sources: `reports/heritage.md`, `platforms/consoles-retro-SUMMARY.md`, `platforms/consoles-modern-SUMMARY.md`, `platforms/haiku/NOTES.md`.

**Minimal program (window + frame + input + sound):** Mega Drive 7 · Vita 8 · Amiga ~12 (2 objects, one thread, no callbacks) · Dreamcast 13 · Switch/3DS 13 · N64 18 · GEM 25 · GameCube ~48 (`reports/heritage.md` §3). A modern Vulkan + GLFW + pad + audio program is ">100 calls, a dozen objects" (an estimate, `consoles-retro-SUMMARY.md`).

**Lost simplicity worth reviving** (`reports/heritage.md` §4, §8):
1. **One wait for everything.** Exec `Wait(sigmask)`: 138 of 418 Amiga `Wait()` calls combine sources. GEM `evnt_multi`. Horizon waits on up to 64 handles. Every source (window, frame, timer, audio, input, file change, IPC) becomes a waitable object.
2. **Self-post wake.** Exec `Signal` to your own port; no separate wake primitive.
3. **A frame clock you can wait on.** `WaitTOF`/vblank; SGDK `SYS_doVBlankProcess` paces, flushes DMA and samples pads in one call. The frame event should carry the *actual* previous present time. An OS that owns scan-out can promise more than the Switch does (it only returns `numPendingBuffers`).
4. **Timers as requests with absolute deadlines** (Amiga `timer.device`), delivered into the same wait, with no global resolution knob.
5. **One request/reply protocol for all devices.** Exec IORequest `DoIO/SendIO/WaitIO/AbortIO` "is essentially 9P"; add protection by never passing pointers between tasks.
6. **Shared-memory rings for fast state.** Horizon HID, time and GSP are rings mapped into the app (reading input costs zero IPC), plus one notification handle.
7. **Known, exact budgets** (PS1 1 MB VRAM, DS 2048 polys/frame, MD 7,200 B DMA per vblank). Translate this to a per-task CPU+GPU grant that "does not shrink without notification".
8. **Audio off the app's RT path:** a DSP/system mixer with a fixed period (NDSP 4.9 ms, audren 5 ms) → `AUD.voice`.
9. **Reserved cores and strict priorities** (Switch core 3 belongs to the system). Turned around: keep daemons off the foreground app's cores.
10. **Nothing compiled at runtime.** Microcode shipped precompiled; state is register writes (DC `pvr_poly_compile` takes microseconds) → baseline dynamic state plus install-time pipeline caches.
11. **Explicit power modes** (`THR.perfmode`: Switch apm, dock/undock events) as intents.
12. **System UI drawn inside the app's frame** (Vita common dialogs) instead of modal loops.

**Do not copy:** global locks (Exec `Forbid`, GEM `wind_update`, which still freezes the XaAES desktop); modal loops inside platform calls (`form_do`); client-redrawn expose as the only damage model (GEM redraw storms); pointer-passing IPC; manual cache flushes before DMA, the ancestor of barriers (`reports/heritage.md` §5).

**FreeMiNT/XaAES API-evolution lesson** (§6): additive changes worked (new syscall numbers, services as files, per-process opt-in, capability queries, explicit-context `mt_*` variants). **Semantics baked into v1 could never be removed.** So v1 of the window protocol must ship with no global lock, no modal loops and capability queries from day one.

**Horizon IPC ≈ Mach ≈ 9P** (`consoles-modern-SUMMARY.md`): name server, capability sessions, sync request/reply, handle passing, object multiplexing (CMIF domains ≈ fids). Three habits to keep: services return waitable kernel objects; high-rate state goes through shared memory; hide per-service init/exit ceremony in the toolkit (lazy sessions).

**BeOS/Haiku** (`platforms/haiku/NOTES.md`; `reports/friction-triage-system.md` §6):
- **Good:**
  - Integer-id kernel primitives with `_etc` timeouts; `snooze_until` (the absolute-deadline sleep F-203 wants); `wait_for_objects`.
  - Areas cover both reserve and share.
  - `BDirectWindow` hands the client the framebuffer plus visible clip list with START/MODIFY/STOP: a working resize and visibility handshake.
  - One B_KEY_DOWN carries raw key, modifiers and UTF-8, with server-side repeat (F-210's model).
  - Synchronous global geometry and server-side decorators (the cheap side of F-206/F-207).
  - The Media Kit's explicit latency, time sources and kit-created RT threads are "the richest model in the study" and the F-216 reference.
  - Node monitoring and live attribute queries (relevant to a modernised BeFS).
- **Bad:**
  - **Per-window looper threads with no app-owned loop**: SDL and Godot ports run BApplication on a helper thread and marshal every event. Lesson: neither "one blessed thread" nor "the toolkit owns every thread". Readiness must be an fd-like object the app can wait on.
  - Media Kit nodes cost hundreds of lines of boilerplate.
  - No native GPU API, swapchain, timing feedback, per-output scale, pointer lock, gamepad hotplug or async I/O.
  - IME is per-view message handling.

---

## 7. The ndtk prototype and what S7 proved

Sources: `prototypes/ndtk/API.md`, `prototypes/ndtk/SHIM-NOTES.md`, `prototypes/results/comparison.md`, `prototypes/results/manual-checks.md`, `reports/s7-prototypes.md`.

**API shape** (Swift, with a C ABI in `prototypes/ndtk/include/ndtk.h`):
- **`Loop`** (one per thread that runs one, any number per app): `wait(until: Deadline?, leeway:) -> Events`, `poll()`, `wake()` (coalesced), `post(Message{a,b})`, `timer(at:leeway:repeating:)`, `watch(fd:)`. `Deadline` is monotonic ns. `Events` borrows the loop's arena and is valid until the next wait.
- **`Event`** = `{kind: UInt16, window: WindowID, time: ns, seq, payload}`. Payloads: `key` (USB HID scancode, keysym, mods, repeat, text span), `text`, `preedit`, `pointer` (with pen fields), `wheel`, `relative`, `configure` (logical size, pixel size, rational scale, configSeq, visible/focused/interactive), `frame` (frameSeq, presentedAt, target, refresh, flags `.presentedEstimated`/`.throttled`), `gamepad`, `timer`, `fd`, `message`, `wake`, `audio(AudioContract)`, `close`, `quit`. C ABI: 72-byte `ndtk_event` records.
- **Windows:** `openWindow(title, size:)` (logical points) → `WindowID{index, generation}`; `set(w, .title/.size/.show/.hide/.fullscreen/.cursorVisible/.pointerLock/.textInputRect)`; `requestFrame(w)` (coalesced, answered by `.frame`); `setLatency(w, frames:)`.
- **Surfaces:** `CPUSurface: ~Copyable` with `pixels: MutableRawSpan`, `age` (EGL-style buffer age) and `fill`; `present(w, consuming surface, damage:, configSeq:)`. GPU path: `gpuSurface(w) -> GPUSurfaceHandle` (a handle bag passed to `webgpu.h` or Vulkan WSI) plus `presented(w, configSeq:)`. Resize is never an error.
- **Audio:** `AudioStream.open(format, periodFrames:, loop:, render:) throws(AudioError)` (pull, on a toolkit-owned RT thread) or `openPush`/`write`; `contract` (period, rate, latencyNs, device, sample-time↔host-ns anchor); `underruns`. Tier 2: `Mixer.shared(loop:).play(buffer, gain:, loop:) -> VoiceID`.
- **Threads:** `spawn(intent: .interactive|.throughput|.background|.audio)`; no affinity API. `sleep(until:leeway:)`. `lastError()` is thread-local.
- **UI (`NDTKUI`):** a slot-table node store with `NodeID` generation handles; one-expression construction (`column(row(label, slider), …)`); row/column flex measure+arrange; class-name styling from a `Theme` with dot fallback (`"label.param"` → `"label"`); `handle(event) -> UIEvent` returns values, not callbacks; `draw()` on `.frame` repaints damage only, presents nothing if nothing changed, and uses a bump frame arena; `export()` dumps the node table as text.
- **GPU decision:** `webgpu.h` for drawing and Vulkan as the seam, plus (after S7) **a one-call helper returning a configured device, queue and surface**.
- **No call runs a nested loop**; dialogs are async objects.
- **Frame loop idiom** (`prototypes/minimal/ndtk/Sources/main.swift`, 36 LOC):

```swift
let loop = Loop(); let window = loop.openWindow("minimal", size: Size(640, 360))
loop.requestFrame(window)
main: while true { for e in loop.wait() { switch e.payload {
  case .configure(let c): configSeq = c.configSeq; if c.visible && !played { Mixer.shared(loop: loop).play(tone) }
  case .frame(let f): guard var s = loop.cpuSurface(window) else { break }
       s.fill(color(f.target)); loop.present(window, s, damage: nil, configSeq: configSeq); loop.requestFrame(window)
  case .key(let k) where e.kind == .keyDown: if k.keysym == Keysym.escape { break main }
  case .close, .quit: break main
  default: break } } }
```

**S7 results (macOS host, 60 Hz; `reports/s7-prototypes.md` §1, `prototypes/results/comparison.md`):**

| Check | Result |
|---|---|
| Minimal: calls to window+frame+input+sound | **ndtk 12 sites (C ABI 10)**, SDL3 11, native 40. Bar: Amiga ~12, Switch 13. Pass |
| Game loop to first GPU frame | 10 ndtk + **26 `webgpu.h`** = 36, against SDL3 Renderer 18 → GPU setup is verbose (hence the one-call helper) |
| Frame pacing p99 error | ndtk **0 ms** (actual presentedTime); SDL3 ≈6 ms (no feedback). Under live resize: p99 33 ms, 22/466 dropped, because Metal reports no present time during resize |
| Live resize | 88 configures → 88 presents at the new size, configure→present p50 9 ms / max 18 ms, loop never blocked. A conventional AppKit pump stalled **2,092 ms** |
| Text editor | **44 LOC** of app code (over a 1,163-line UI module) vs 365 (SDL3) and 367 (native); 0 dropped of 592 frames; draw 1.0 ms p50 at 1800×1400; 0 allocations in layout/paint; arena high-water 1.5 KB; IME (Japanese/Pinyin) passed by harness and by a human |
| Synth | 0 underruns in 22,831 callbacks at 128 frames; contract latency 8.44 ms (matches native); render path compiles under `@_noLocks`/`@_noAllocation`, and a deliberate violation fails to build. SDL3 takes **3 locks per callback** internally and actually delivers 4×128 bursts every 10.67 ms with ≥32 ms latency it doesn't report |
| Compute → display | zero-copy via `webgpu.h` **after a 7-line wgpu-native patch** (STORAGE_BINDING dropped for surfaces); SDL3 has 1 unavoidable copy |
| Idle | ndtk 0 wakeups/s; native minimal 61/s (MTKView keeps drawing) |
| One wait | timers, fd readiness, post, wake and a real audio-contract change all arrive through one `wait`, on main and background loops |
| GPU budget | **not tested** for ndtk |
| Timers on host | zero-leeway timer 0.5–1.7 ms late (CFRunLoop limit; F-203 unproven) |

**Shim cost** (`SHIM-NOTES.md`): about 1,100 lines exist only to hide macOS rules. The largest items: a 107-line AppKit "dispatch fiber" with 57 lines of arm64 asm so `wait` returns inside the live-resize loop (high risk); ~200 lines building one wait from CFRunLoop parts; ~190 lines assembling the audio contract from five HAL properties. All of it disappears on an OS with no main thread, no modal loop, one kernel wait and an audio service.

**Charter changes S7 forced** (`reports/s7-prototypes.md` §3):
1. A one-call GPU-surface helper.
2. Upstream the wgpu-native fix or use Dawn.
3. **GPU surface size independent of window size** (a viewporter-style request).
4. **Swift on RT audio threads works but is narrow.** No libm, no first-use of a class (metadata realisation allocates and locks), no `&&`/`||` in `@_noLocks` code (the autoclosure captures self). Apple marks `os_workgroup` unavailable in Swift. Offer a C trampoline option.
5. CPU surfaces need actual present feedback too.
6. **Text shaping (HarfBuzz-class) is missing**; the prototype uses one scalar = one glyph.

---

## 8. Open questions the study left unresolved

- **GPU budget and residency (F-108/F-109):** untested in S7; no design exists.
- **Present-time accuracy on a real compositor:** all S7 timing is host-estimated for CPU surfaces; NeoDarwin numbers wait for wsys.
- **120 Hz scrolling:** untested (no 120 Hz display). **F-203** deadline-sleep accuracy (the p99 < 100 µs target) was never measured on a real kernel.
- **Pen (F-212) and address-space/JIT (F-218):** no prototype exercises them; small add-on checks are proposed but not built.
- **Immediate-mode UI layer:** deferred; the retained core was enough for S7.
- **Callback driver** (`NDTK.run`): compiled only; push audio, Cmd-Q and window close never exercised (`SHIM-NOTES.md` "Not done").
- **Device-loss contract:** deferred to the GPU owner.
- **GPU-direct storage (IO.gpu.direct):** no evidence because the corpus has no AAA streaming engine (a corpus gap, not a negative result).
- **CUDA-shaped compute host API:** "P7 research".
- **Wayland server effort, libwayland kqueue port, epoll shim and x86 emulation:** all unmeasured.
- **Event mask overflow** (30 of 32 types already planned): widen it before v1.
- **Swift RT checker gaps:** it cannot see into C or trust libm.
- **Native Win32/Wayland prototype variants:** never built.
- Corpus and data fixes listed as unfinished: issue-tracker mining, `backends.yaml` omissions, the CRLF bug, generated-file filtering.

---

## 9. For Todhchai: adopt, adapt, ignore

### Adopt directly
- **The ndtk shape, nearly verbatim**, in Swift with a C ABI: app-owned `Loop` with `wait(until:leeway:)`/`poll`/`wake`/`post`/timers/fd watch; the tagged event record with ns timestamp and generation `WindowID`; borrowed payload spans valid until the next wait; `requestFrame` → `.frame{presentedAt, target, refresh, flags}`; `.configure` with `configSeq`; presents tagged with that seq; `setLatency(n)`. This is the backbone for both hobbyists (≈12 calls to sound) and AAA (exact timing, no hacks).
- **No main thread, no modal calls, async dialogs, no thread affinity:** v1 rules that can never be added later (heritage §6).
- **Generation handles at every boundary** (u64 index+gen) and **two memories** (per-frame bump arena + slot-table nodes). Both suit Embedded/allocation-free Swift (`~Copyable`, `Span`). They also match Handmade Hero's arena discipline and console fixed budgets.
- **Two-tier audio:** a pull/push stream with one contract record, plus a system voice mixer with a fixed period.
- **Server-owned input semantics:** USB-HID scancode + post-event mods + unmodified rune + server repeat (F-210); IME beside the compositor with preedit/commit events and a toolkit text adapter (F-211); server-side pointer lock with raw deltas (F-213); pen fields with HID tool types (F-212); one kernel/driver gamepad class with a controller DB as data (F-214).
- **The BeOS-friendly window-system decisions** the study validated: server-side decorations with client title-bar regions (F-207); synchronous, seq-acknowledged geometry and anchored popups (F-206); per-window rational scale (F-205); server-computed visibility with a throttled, never-withheld frame clock (F-209).
- **GPU stack:** Vulkan via Mesa as the only native GPU API with a published profile (DXVK floor; GPL or shader objects, unified layouts, timeline semaphores, present timing); SPIR-V only; `webgpu.h` (Dawn) as the toolkit draw API plus a **one-call surface helper** for hobbyists; Vulkan seam for engines; no Metal, no SDL_gpu clone; Zink for GL. Ship a system render-graph/barrier library (F-106) and a pipeline-cache service (F-103).
- **Thread intents, not priorities** (F-204), and an RT admission test with an unprivileged budget (F-215).
- **Measurable exit criteria:** ≤13 calls to sound, frame error p99 ≤1 ms, 0 idle wakeups, 0 callback locks/allocations (compiler-checked), zero-copy compute→display.
- **Polled-state convenience layer** (raylib `IsKeyPressed`, gamepad snapshot) and the **SDL3-style callback driver**, both as thin layers over the queue: the indie on-ramp.
- **Text shaping** in the plan from day one (the gap S7 found).

### Adapt (Zircon-style microkernel instead of XNU/Mach + 9P)
- **"One wait" = `zx_port_wait`.** Bind every source with `zx_object_wait_async`; wake/post = `zx_port_queue` user packets (replacing EVFILT_USER); deadlines = `zx_timer` with absolute deadline + slack, which *is* F-203's "deadline + leeway" contract with no resolution knob. Zircon already gives you the Exec/Horizon shape; the F-201 "readiness on 9P fids" requirement becomes "every service hands out a waitable handle" (the Horizon habit, `consoles-modern-SUMMARY.md`).
- **Window/audio/input protocols over channels, not 9P files.** Keep the study's text-ctl and "data is the interface" ideas for observability, but put the fast paths in **shared VMO rings + one notification handle** (Horizon HID; Zircon `zx_fifo` or VMO + event pair). Input state, frame timing and audio anchors should all be readable without an IPC round trip.
- **GPU buffer object (F-107) = VMO + format/modifier + fence handle** (Zircon events or counters as a timeline). Host-memory import (F-108) = pin via BTI/PMT behind the IOMMU (croi treats the IOMMU as core). Budget (F-109) = kernel accounting of VMO-backed GPU memory plus a memory-pressure event. **Fuchsia magma (26k lines; `reports/q5-compat.md` C3) is your direct precedent** for running Mesa Vulkan drivers over a non-DRM uAPI, and `~/Projects/OS/fuchsia` is already on disk.
- **RT audio (F-215):** map `realtime(period, computation, constraint)` onto a deadline scheduling profile (Zircon-style deadline profiles). Add the explicit admission test and per-user budget the study asks for; read Zircon's semantics before assuming it refuses rather than degrades.
- **F-218 VM views and JIT:** VMAR allocate (specific/fixed) + map VMO views + replace-as-executable already model reserve/map_view/JIT. Expose them as a documented userland API, not a raw syscall recipe.
- **F-217 async I/O:** there is no in-kernel io_uring. Storage drivers live in userspace, so the "submission/completion ring" is a shared-memory fifo protocol to the block/FS server, with a waitable completion handle. A modernised BeFS server is where per-request cache policy, node monitoring and live queries live.
- **F-214 gamepads / F-212 pens:** "kernel HID class" becomes a userspace driver-host HID class service. Same normalised device record, same controller DB.
- **F-219 loaders:** one versioned SDK/ABI level with availability annotations (Fuchsia's API levels are a precedent); optional services are capabilities you request, so absence is an error, not a dlopen probe.
- **Compatibility (Q5):** POSIX through a userland libc shim (fdio-like), entering ports as a "Linux-like Unix" with your own target macro; Wayland core+ door later; SDL3 backend early (audio + HID, ~1–2k lines; video modelled on Haiku's 3k-line backend).
- **Haiku lesson for the BeOS-inspired desktop:** keep Be's server-side decor, sync geometry, rich media latency and node queries, but **do not** bind a looper thread to each window. Per-window serialisation, yes; toolkit-owned threads, no.

### Ignore / deprioritise
- Darwin source compatibility and anything Mach/XNU-specific (QoS names, `mach_absolute_time`, kexts/dexts, libSystem, Wine's Darwin `ntdll` path). The study itself shows it buys ~1.4% of usage.
- Metal; an SDL_gpu-shaped API; a new shading language or object model; OpenCL/SYCL/CUDA-shaped compute in v1 (Vulkan compute only).
- Wine/DXVK/x86 emulation, Xwayland and the PulseAudio door until the native stack exists.
- `libintuition`'s specific choices that the study rejected: arena-only retained tree, pointer-graph nodes, integer-pixel units, the reader-proc+channel loop (`reports/q2-shapes.md` §6).
- Obsolete-hardware mechanisms (bitplanes, copper, tile VDPs). Keep the *intent* (frame clock, command list, budgets), not the mechanism.
- The study's corpus tooling (`studyctl`, DuckDB) unless you want to re-run it against croi's own APIs.
