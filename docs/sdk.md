# SDK design

The SDK has to serve three audiences without hiding the lower layers from any
of them.

| Audience | Wants | Gets |
|---|---|---|
| **Hackers and learners** | a window, pixels, input and a sound in a dozen lines | `Loop` + `CPUSurface` + `Mixer`, polled `Keys`, one-call GPU setup |
| **Indie game developers** | an SDL-like layer, fast iteration, any language | Game Kit, C ABI, hot reload, an arena allocator, Loinnir GPU; SDL3 through SDL's own Todhchai backend |
| **AAA engines** | exact timing, no hidden threads or locks, direct control, raw Vulkan | `Loop` with frame feedback, raw Vulkan, thread intents, memory budgets, direct rings, async I/O rings, pipeline-cache service |

All three use the same core. The convenience layers are thin wrappers over the
event queue, never separate paths.

## 1. Modules

```
libtodhchai (C ABI, plus Swift overlay "Todhchai")
  Loop      one wait: events, timers, fd/handle watches, post, wake
  Window    open/set/close; configure events; decorations and title-bar regions
  Frame     requestFrame, latency, frame events with present feedback
  Surface   CPUSurface (pixels) | GPUSurface (handle bag for Vulkan/Loinnir/WebGPU)
  Input     key/text/IME/pointer/pen/relative/gamepad events + shared-memory state
  Audio     stream (pull|push) + contract; Mixer voices
  Thread    spawn(intent:), sleep(until:leeway:), Mutex/Condition (PI futex), workgroups
  Memory    reserve/commit/decommit/protect/mapView; Arena, Scratch
  Time      monotonic ns, Deadline, wall clock
  File      open/read/write via streams; async I/O ring; batched directory listing
  Query     attributes, indices, queries, live queries (Taisce)
  Code      CodeModule: load, swap on rebuild, fixed-address state block
  Trace     trace points, counters, scoped zones (feed the system tracer)
  Debug     self-inspection; debug-protocol client
  Node      publish a service's /svc tree in ~150 lines; walk/read/write/watch others
  Route     send to and receive from the router (plumber) ports; intent streams
  Auth      keyring sessions: authenticate a connection, sign, never see keys

Loinnir     thin GPU library over Vulkan 1.4 (see §5)
UI Kit      immediate-mode UI with keyed retained cache, themes, a11y tree
Game Kit    polled input snapshot, fixed-step helper, SDL3-shaped callback driver
Media Kit   node graphs with latency accounting, translators
Storage Kit Tracker-grade attribute and query helpers, People/Mail-style schemas
```

## 2. The loop and events

The **app owns the loop**. A `Loop` belongs to whichever thread runs it, and
an app can run any number of them. `wait` blocks on one croi port.

```swift
public struct Loop: ~Copyable {
    public init() throws(LoopError)
    public mutating func wait(until: Deadline? = nil, leeway: Duration = .zero) -> Events  // borrowed, valid until next wait
    public mutating func poll() -> Events
    public func wake()                                     // coalesced; callable from any thread
    public func post(_ m: Message)                         // two UInt64s; cross-thread
    public mutating func timer(at: Deadline, leeway: Duration, repeating: Duration?) -> TimerID
    public mutating func watch(_ h: borrowing Handle, signals: Signals) -> WatchID
}
```

An **event** is a fixed-size tagged record (80 bytes at the C ABI). Fields:

```
kind: UInt16 · flags: UInt16 · window: WindowID {index: UInt32, gen: UInt32}
time: UInt64 (monotonic ns, hardware timestamp when available) · seq: UInt64
payload: 48-byte union; variable data (text, drop lists) is a borrowed span valid until the next wait
```

Event kinds:
- **Input:** `keyDown`, `keyUp`, `text`, `preedit`, `commit`, `pointer`,
  `wheel`, `relative`, `pen`, `proximity`, `gamepad`.
- **Window:** `configure` (logical size, pixel size, scale as n/120,
  `configSeq`, visibility, focus, interactive), `close`.
- **Frame:** `frame` (frameSeq, target time, presentedAt of the previous
  frame, refresh interval, flags such as `estimated` and `throttled`).
- **Other sources:** `audio` (contract changed), `timer`, `watch`, `message`,
  `wake`, `memoryPressure`, `ioComplete`, `queryUpdate`, `quit`.

The subscription mask is 64 bits from day one; the NeoDarwin mask was nearly
full at 32.

**Rules:**
- No call runs a nested loop.
- Resize is never an error.
- Hidden windows get a throttled frame clock (about 1 Hz), never a stalled one.
- Every buffer presented to a window carries the `configSeq` it was drawn for,
  and the compositor never stretches a mismatched one (F-208).

## 3. Minimal programs

The bar is about 12 calls for window, frame, input and sound.

**Swift**
```swift
import Todhchai

var loop = try Loop()
let win = try loop.openWindow("hello", size: Size(640, 360))
let beep = try Sound.load("/data/beep.wav")
var seq = ConfigSeq.zero
loop.requestFrame(win)

main: while true {
    for e in loop.wait() {
        switch e.payload {
        case .configure(let c): seq = c.configSeq
        case .frame(let f):
            guard var px = loop.cpuSurface(win) else { break }
            px.fill(.hsv(Double(f.target.ns % 4_000_000_000) / 4e9, 0.8, 1))
            loop.present(win, consume px, configSeq: seq)
            loop.requestFrame(win)
        case .keyDown(let k) where k.usage == .space: Mixer.shared.play(beep)
        case .keyDown(let k) where k.usage == .escape: break main
        case .close, .quit: break main
        default: break
        }
    }
}
```

**C** (the same calls, through the generated header)
```c
#include <todhchai/todhchai.h>
int main(void) {
    td_loop *loop = td_loop_create();
    td_window w = td_window_open(loop, "hello", 640, 360);
    td_sound beep = td_sound_load("/data/beep.wav");
    uint64_t seq = 0;
    td_frame_request(loop, w);
    for (;;) {
        td_events ev = td_loop_wait(loop, TD_FOREVER, 0);
        for (size_t i = 0; i < ev.count; i++) {
            const td_event *e = &ev.items[i];
            switch (e->kind) {
            case TD_EV_CONFIGURE: seq = e->configure.config_seq; break;
            case TD_EV_FRAME: { td_cpu_surface s;
                if (td_cpu_surface_acquire(loop, w, &s)) { td_fill(&s, 0xff00ffcc);
                    td_present(loop, w, &s, seq); td_frame_request(loop, w); } } break;
            case TD_EV_KEY_DOWN: if (e->key.usage == TD_KEY_SPACE) td_mixer_play(beep, 1.0f);
                                 if (e->key.usage == TD_KEY_ESCAPE) return 0; break;
            case TD_EV_CLOSE: case TD_EV_QUIT: return 0;
            }
        }
    }
}
```

## 4. Windows, surfaces and frames

- `openWindow(title, size:, kind:)`, where `kind` is `toplevel`, `transient`,
  `popup` (anchored, xdg_positioner semantics), `tooltip` or `fullscreen`.
  Geometry requests are synchronous and acknowledged with a seq (F-206).
- **Decorations** belong to the server and use the BeOS yellow-tab lineage.
  An app can take over the title strip with `.clientTitlebar` and declare
  `drag`, `button` and `noDrag` regions. The server still does hit-testing,
  snapping and the move/resize loop (F-207).
- **Scale:** each window gets one rational scale (n/120). Sizes are logical
  points, and `configure` carries both the logical and the pixel size (F-205).
- **Frames:**
  - `requestFrame(w)` is coalesced, and the answer is a `.frame` event that
    carries the target scanout time and the actual time the previous frame was
    presented.
  - `setLatency(w, frames:)` is the single queue-depth number, and presents
    fail fast past it (F-102).
  - `present(..., at: Deadline?)` requests a target time.
  - Presentation also reports whether the frame went by direct scanout, an
    overlay plane or composition, so an engine can see why it missed, and
    whether its times are measured at vblank or estimated (a firmware
    framebuffer has no vblank interrupt; see [desktop.md](desktop.md) §1).
    An async (tearing) present is honored only on a plane; otherwise the
    feedback says it waited for the next latch.
  - If the compositor restarts, the SDK reconnects and replays the
    window; the app sees a `configure`, not an error.
- **Surfaces:**
  - `CPUSurface: ~Copyable` gives `pixels: MutableRawSpan` and `age` (buffer
    age, for partial redraw).
  - `GPUSurface` is a handle bag for `VK_KHR_todhchai_surface`, Loinnir or
    WebGPU, plus a surface size independent of the window size
    (viewporter-style scaling), which the NeoDarwin prototypes found
    necessary.

## 5. GPU: Vulkan underneath, Loinnir on top

**Decision (proposed):** Vulkan 1.4, through Todhchai's own drivers, is the
only native API. The SDK's own GPU library, **Loinnir** (Irish for "radiance"), is a thin API in
Sebastian Aaltonen's "No Graphics API" style, implemented directly on Vulkan
1.4 features (buffer device address, descriptor heaps, unified image layouts,
dynamic rendering, shader objects, timeline semaphores).

```swift
let gpu = try Loinnir.open(window: win)              // device, queue, swapchain in one call (NeoDarwin S7)
let verts = try gpu.alloc(MemoryKind.upload, bytes: 64 << 10)   // returns a CPU-mapped pointer + GPU address
let tex = try gpu.texture(.rgba8, 512, 512)                     // 32-bit index into the global heap
let pso = try gpu.pipeline(vs: spirvVS, fs: spirvFS, targets: [.bgra8])  // microcode state only; built at install
var cmd = gpu.commands()
cmd.render(to: gpu.backbuffer) { r in
    r.draw(pso, root: rootStruct, vertices: 3)     // one 64-bit root pointer per draw
}
gpu.submit(consume cmd, signal: gpu.timeline + 1)  // 64-bit timeline counter
```

Why Loinnir and not `webgpu.h` as the main drawing API (NeoDarwin chose
`webgpu.h`, for portability):
- Todhchai has only one GPU backend, so WebGPU's portability buys nothing
  inside the OS.
- Loinnir has fewer concepts than WebGPU, sits closer to the hardware, and
  reaches AAA without a separate path: bindless indices, explicit memory,
  timeline sync.
- Loinnir is about 1 to 3K lines over Vulkan, all ours. A WebGPU
  implementation is hundreds of thousands of lines, and under principle 29
  it would be ours to write too.

What we keep regardless:
- **WebGPU** stays available, but as a third-party port: Dawn or wgpu
  running on our Vulkan, maintained by their own projects or a separate
  ports collection, for bevy, Zed and egui-class apps. It is never part of
  the Todhchai tree.
- **Raw Vulkan** is always available. `GPUSurface` gives the `VkSurfaceKHR`,
  and the F-107 buffer object imports and exports as Vulkan external memory
  plus a timeline semaphore.
- **System services for every API:**
  - A **pipeline-cache service** keyed by app, shader hash and driver build,
    warmed when an app is installed (F-103).
  - A **render-graph and barrier library** (F-106).
  - The offline **shader toolchain**: Slang or HLSL/GLSL to SPIR-V (F-111).
    These compilers are development toolchains under principle 29: they run
    at build time, and nothing from them ships.

Hardware cost: Loinnir needs descriptor-heap and BDA-class hardware (roughly
RDNA2, Xe and Turing or newer). That fits the published hardware list
(principle 21). Older GPUs, where our drivers support them, can still use raw
Vulkan.

Aaltonen's "NoGraphicsAPI" library (reported September 2026) and his talk
are design references only. Loinnir is written from his published design and
the Vulkan specification, not from that library's code.

## 6. Input

- Event-driven input is described in §2.
- **Polled state** reads the shared-memory ring with no IPC:
  - `Keys.down(.w)`, `Keys.pressed(.space)` (edge since the last frame);
  - `Pointer.position`, `Pointer.delta`;
  - `Gamepads[0].stick(.left)`, `.button(.south)`.

  This is raylib's model, as a convenience over the event queue.
- **Gamepads:** one enumeration, SDL_Gamepad-shaped button and axis names,
  rumble, gyro, and hot-plug events. The controller database is data.
- **Pointer lock:** `set(w, .pointer(.locked | .confined | .free))`.
  Relative motion is always available, unaccelerated (F-213).
- **Text:** an `.ime` window property (enable, caret rect, purpose,
  surrounding text) plus preedit and commit events. The UI Kit's text field
  handles this. A C app can do it in about 50 lines.

## 7. Audio

```swift
@AudioRenderer                       // the compiler checks render: no allocation, no locks
struct Synth {
    var voice = Voice()
    mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
        voice.render(into: out, at: time)
    }
}
let stream = try AudioStream.open(.f32(channels: 2, rate: 48_000), periodFrames: 128, renderer: Synth())
stream.contract   // period, rate, latency (end to end), device
stream.underruns  // periods rendered too late to be heard on time
```

- **The callback is a type, not a closure.** `@AudioRenderer` puts
  `@_noAllocation` on its `render`, so the compiler rejects allocation,
  locks and reference counting there. A real-time callback that could
  glitch fails to build. Closures can't carry that check, which is why
  this differs from the closure the design first sketched (decided in
  M1e, 2026-10-09).
- **Pull** streams run on an SDK-created real-time thread that has already
  passed admission. **Push** streams use `write`.
- **Contract** changes, such as switching device, arrive as `.audio` events.
  Underrun counters are readable.
- **Voices:** `Mixer.shared.play(sound, gain:, pan:, loop:) -> VoiceID`.
- **Exclusive mode:** `AudioDevice.openExclusive()` maps the device ring.
  This needs a capability grant.

## 8. Threads and memory

- `Thread.spawn(intent:)` with the intents in architecture §8. There is no
  raw priority or affinity API. Topology is published as data for engines
  that schedule their own jobs.
- `Mutex` and `Condition` sit on priority-inheriting futexes.
- `Workgroup` ties an engine's job threads to a frame or audio deadline so
  the scheduler treats them as a unit.
- **Swift concurrency:** a native `TaskExecutor` runs over ports. Game job
  systems can provide their own executor (SE-0417). `async` is for loading,
  I/O and control paths. Real-time paths stay synchronous.
- **Memory:** `Arena` (reserve, then commit on demand), `Scratch` (thread
  local, two-deep), `Pool<T>` (a slot table with generation handles), and
  `Memory.reserve/commit/...` for direct control. `Memory.budget` and
  `.memoryPressure` events cover CPU and GPU together.
- **ARC discipline:**
  - Kit APIs are written over `~Copyable` structs, `Span` and arenas, so a
    frame loop does no retain or release.
  - Classes are allowed at the edges (app delegates, documents).
  - CI profiles `swift_retain` counts in the reference programs and fails on
    regressions.

## 9. Files and queries

```swift
let f = try File.open("/data/save.bin", .read)                  // stream-backed reads at syscall speed
var io = try IORing(loop: &loop, depth: 256)
io.read(f, range: 0..<(1 << 20), into: arena)                   // completes as .ioComplete on the loop

for entry in try Directory.list("/vol/home/music", attributes: ["Audio:Artist", "Audio:Title"]) { … }

let q = try Query("((Audio:Artist == \"Kraftwerk\") && (Audio:Year < 1982))", volume: .home, live: true)
// results stream as .queryUpdate events on the loop; resumable by change-journal sequence
try f.attributes["Game:LastPlayed"] = .time(.now)
```

## 10. UI Kit

- **Immediate-mode API, with retained state underneath.** Widgets are
  function calls made every frame, keyed by id, with Fleury and RAD Debugger
  style caching across frames. Layout is a two-pass flex (measure, then
  arrange). Per-frame data lives in an arena, and node state in a slot table.
  This is the shape the NeoDarwin study found UI libraries converging on
  (its C11), presented the Handmade way.
- If nothing changed, `draw()` presents nothing. There are no idle wakeups.
- Styling belongs to the **theme** (class names with dot fallback, such as
  `"label.param"`). The cyberpunk look is the default theme. See
  [desktop.md](desktop.md) §6.
- Every frame also produces an **accessibility tree** as a side output: roles,
  labels, focus and actions. A screen reader consumes it over IPC.
- Text uses the system's own OpenType shaper and glyph atlas (architecture
  §13).
- The shell and system apps are built with this kit (principle 25).

## 11. Game Kit

- `GameLoop.fixedStep(hz:)`: an accumulator, interpolation alpha and pacing
  from frame feedback.
- An `App` protocol driver shaped like SDL3's callbacks (`init`, `iterate`,
  `event`, `quit`), for people who want callbacks. It is about 100 lines over
  `Loop`.
- `CodeModule` hot reload: the platform owns a state block at a fixed address
  in a reservation, and the game module is swapped when its file changes.
- Record and replay: snapshot the game's reserved range, then loop recorded
  input.
- An SDL3 backend for Todhchai, contributed to and maintained in SDL's own
  tree, so existing SDL games build unchanged. It is SDL's code, not ours,
  and it isn't in the Todhchai tree (principle 29).

## 12. C ABI conventions

- Prefix `td_`. Opaque objects are pointers only where an object's lifetime is
  local to the process (`td_loop*`). Everything else is a 64-bit generation
  handle.
- Every input struct starts with `uint32_t size`, so newer fields can be added
  and older callers still work. Output structs are allocated by the caller.
- Fallible calls return `td_status`, or an invalid handle or `NULL` for
  constructors, and `td_last_error()` gives thread-local detail. Nothing
  panics on misuse; a stale handle is diagnosed and ignored.
- No callbacks, except audio render and the optional App driver. Both are
  documented as running on SDK-owned real-time threads.
- Headers are generated by `idlc` together with the overlays. The generator
  also produces `todhchai.zig`, `todhchai.odin`, a Rust `todhchai-sys` crate
  and a Jai module.
- `libtodhchai` is built in Embedded Swift, so a C game never pulls in the
  full Swift runtime. It is normally linked dynamically against an API level,
  and a static build is available (architecture §14).

## 13. Tools

- `td build`: one command builds a single-file app. It accepts a unity build,
  with no project file required. The target is a "hello window" build in under
  1 second.
- `td run --hot`: watches the source, rebuilds the code module and swaps it.
- `td trace`: records and views a system timeline (CPU, IPC, frames, audio,
  GPU).
- `td debug`: the native debugger, a client of `debugd`.
- `td bundle`: appends resources and attributes to the ELF to make the
  single-file app.

## 14. Reference programs (S7 for Todhchai)

Each one is written against the SDK, first in hosted mode and then natively.
The exit criteria come from NeoDarwin and the Handmade discussions:

| Program | Exit criterion |
|---|---|
| minimal | ≤ 13 calls to window+frame+input+sound; 0 idle wakeups/s |
| game loop (Loinnir) | frame error p99 ≤ 1 ms against present feedback; one-call GPU setup |
| text editor | 0 dropped frames while typing; 0 allocations in layout/paint; IME works |
| synth | 0 underruns at 128 frames; compiler-checked lock- and allocation-free callback |
| compute → display | zero copies end to end |
| terminal | termbench within 2× of refterm |
| file browser | 100k-entry directory listed and sorted in < 100 ms (warm) |
| hot reload | rebuild-and-swap < 1 s for a 10K-line game module |
