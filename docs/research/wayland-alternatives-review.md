<!-- SPDX-License-Identifier: BSD-3-Clause -->
2026-10-10

# Review: "Architecture Beyond Wayland" against Radharc's design

This reviews an outside paper, *Architecture Beyond Wayland: Diagnostics,
Alternative Paradigms, and the Technical Specification for
Next-Generation Display Systems*, against what Todhchai has already
decided: [desktop.md](../desktop.md) §1–2, [architecture.md](../architecture.md)
§4–5, §10, §13, §17, §19, [wire-format.md](../wire-format.md) and
[sdk.md](../sdk.md) §4, §6, §10. For each of the paper's claims it asks
three things. Does the claim hold? Does our design already answer it? Is
there a fix we should adopt while the compositor is still on paper (M4
builds it)?

R1–R7 below were folded into the design on 2026-10-10: desktop.md §1
("Privileged services", "Crash survival", the protocol and game-mode
notes), architecture.md §3, §13, §15, §17, §19, sdk.md §4 and roadmap.md
M4 and M6.

## Summary

- **Most of the paper's prescription is already in our design.** The
  protocol uses hashed 64-bit ordinals, native 64-bit and aligned fields,
  zero-copy decoding, explicit timeline sync and plane-first scanout with
  opt-in tearing. One canonical compositor serves one native protocol, and
  authority comes from handles. Where the paper and our documents agree,
  nothing needs to change.
- **The paper's strongest point is one we haven't designed: privileged
  desktop interfaces.** These are screen and window capture, synthetic
  input, global shortcuts, input monitoring for assistive technology, and
  window enumeration. Wayland pushed them out to portals and daemons. We
  have half the ingredients (the accessibility tree, typed `wctl`, the
  control-only window-manager handle, grants by user prompt) but no
  protocol. This is the main recommendation (R1).
- **Compositor crash survival** is worth taking. We can get it more cheaply
  than the paper's split-process design, through SDK reconnect and replay
  (R3).
- **Reject:** Cap'n Proto or FlatBuffers, "cryptographic capability
  tokens", Lua policy scripting, and in-protocol video codecs for now.
  The first three duplicate what we have. The last is too large to write
  ourselves yet (principle 29).
- **Source quality is mixed.** Many of the paper's citations are forum
  threads and gists, and several claims are overstated (see "Claims to
  discount"). Its conclusions are more useful than its diagnosis.

## Point by point

### 1. Presentation latency and scanout

**Paper:** Wayland forces composition, which adds one or two refresh
intervals. Direct scanout and tearing came late. A successor needs
immediate (tearing) presentation and multi-plane direct scanout.

**Ours:** desktop.md §1 "Frame scheduling" already orders the work as
direct scanout, then overlay planes, then composition latched late on
async compute. Game mode adds async flips on request, VRR with
low-framerate compensation, and the display engine's color LUTs. sdk.md §4
reports which path each frame took and whether its times were measured
or estimated. The present credit bounds queue depth. Principle 23 makes
this order a rule.

**Verdict:** covered, and ahead of the paper on feedback. One gap is in
how the design is worded:

- Tearing only means something for a surface on a plane. A composited
  window can't tear, because the composite is what flips. desktop.md says
  "Tearing is allowed when the client asks" under game mode, which a reader
  can take as applying to any window. **Fix (small):** say that an async
  present is honored when the surface is scanned out (primary or overlay
  plane). Otherwise it degrades to "next latch", and present feedback says
  so. Consider promoting a focused windowed game to an overlay plane when
  the hardware allows it, so windowed play can tear too. This is Windows'
  Independent Flip for windows.

### 2. Synchronization

**Paper:** implicit DMA-BUF sync caused years of stutter, so a successor
must use explicit timeline semaphores only.

**Ours:** the GPU buffer object carries a timeline counter (F-107). Every
image is presented with an acquire value, and the compositor returns
release values. No implicit path exists to remove.

**Verdict:** covered. One wire constraint to respect: wire-format.md says
**events can't carry handles yet**. So release must remain a *counter
value* on the buffer's own timeline (the `released(BufferID)` event in
architecture §4 already does this), never a fence handle per frame. Keep
it that way when the protocol is written. It is also cheaper.

### 3. Isolation versus capabilities

**Paper:** Wayland isolates every client and offers nothing built in for
automation (xdotool), accessibility (screen readers, dwell click, eye
tracking), screen capture (OBS, magnifiers) or global hotkeys. Each now
goes through D-Bus portals, PipeWire, libei or uinput, and every desktop
implements them differently. The fix is in-protocol, capability-governed,
first-class privileged interfaces.

**Ours:**
- Authority is already capabilities: handles and namespaces (§5, §17).
  Grants for direct rings already go through a user prompt and are recorded
  in the app's attributes (§5 "Direct access by grant").
- The UI Kit emits an accessibility tree each frame (sdk.md §10). Scripting
  has addressable state, an intent stream, and claim and decline
  (desktop.md §3).
- Window control is typed and multi-subscriber. A control-only
  window-manager handle exists for tools such as a taskbar (desktop.md §1,
  "Nesting").
- What's missing is any design for capture, input injection, global
  shortcuts or input monitoring. "Screenshot" appears only as something a
  buffer object can hold (§10). The accessibility tree has a producer and
  no consumer: nothing says how a screen reader learns where a node is *on
  the screen*, which needs the compositor's transform from window to
  output.

**Verdict:** the paper is right, and this is the one place where our
design is closer to Wayland's gap than to its fix. The paper's
"cryptographic capability tokens" are unnecessary here: a croi handle is
already unforgeable, transferable and revocable by closing it.

**R1. Adopt: privileged compositor services, one handle each.** Radharc
publishes them as service nodes in its tree. Each one is its own typed
protocol on its own channel, so granting one grants nothing else:

| Service | Gives | Typical holder |
|---|---|---|
| `capture` | a stream of buffer objects for an output, a window or a view subtree, with damage, through the same present-queue ring in reverse | recorder, magnifier, remote desktop, the export bridge later |
| `inject` | synthetic key, pointer, touch and pen records into the input pipeline at a chosen point (before or after focus routing) | automation, switch access, dwell click, remote desktop |
| `shortcuts` | register a chord. The compositor matches it, delivers it as an event and consumes it. The holder never sees other keys | hotkey daemons, push-to-talk |
| `observe` | a read-only input feed (keys with modifiers, pointer position) | screen readers (key echo), on-screen keyboards |
| `windows` | the window list with geometry, focus, workspace and owner signature, plus typed `wctl` verbs. This is the control-only handle, made formal | taskbar, tiling scripts, `hey`-style tools |
| `a11y` | every window's accessibility tree, in screen coordinates, with focus following | screen readers |

Rules that make this better than both X11 and Wayland:
- **Grant model as today.** The manifest asks, the user approves once
  through the trusted prompt, the grant is a recorded attribute and can be
  revoked. Revocation closes the channel.
- **Visible while in use.** Deskbar shows an indicator whenever any
  `capture`, `inject` or `observe` channel is open, naming the holder. The
  compositor knows this without being told, because it serves the
  channels.
- **A trusted path.** Surfaces of the trusted shell prompt (the keyring's
  confirmation, §17) and the login screen are marked secure. They are
  blacked out in `capture` and `a11y` (a screen reader gets their content
  from the prompt itself, over its own channel). They are skipped by
  `observe`, and they **ignore injected input**. Without this, `inject`
  can approve its own grant prompt.
- **Injected input is marked** in the record (a source field). Ordinary
  apps can ignore the mark, so accessibility works everywhere, while the
  trusted path rejects it.
- **Nesting.** A nested Radharc forwards these services to its parent as
  it does clipboard and IME (desktop.md §1). A capture of the nested
  window is then simply a capture of a window.

Each is a small `@IPCLibrary` protocol and fits Node (`cat
/svc/radharc/windows/status`). Before any is written, principle 8
applies: each needs a reference program. The likely ones are a recorder
(capture), a dwell-click tool (inject), and the terminal's `hey` (windows).

### 4. Fragmentation and governance

**Paper:** a protocol with no canonical implementation produced Mutter,
KWin, wlroots and cosmic-comp, a slow consensus process, and fights over
layer-shell and client-side decorations.

**Ours:** one OS, one compositor (Radharc), one native protocol, and
server-side decorations decided (desktop.md §2). Evolution is mechanical
(`@since`, flexible enums, idlc's baseline check), and principle 14 keeps
v1 small.

**Verdict:** this doesn't apply to native apps. The risk lives in the
**Wayland core+ server** (§15). It inherits the arguments, so its scope
should stay what ported toolkits need (the 16 extensions in the NeoDarwin
digest). Shell extensions such as `wlr-layer-shell` stay out: panels on
Todhchai are native replicants, and porting a Wayland panel is not a goal.
Keep that exclusion written down.

### 5. Protocol definition and wire format

**Paper:** XML plus wayland-scanner makes builds harder and complicates
cross-compilation. Opcodes depend on declaration order. There are no
64-bit integers (`modifier_hi`/`modifier_lo`). Destruction races between
in-flight events and destroyed objects. A successor needs a zero-copy IDL,
64-bit alignment, native 64-bit types and hashed interface identifiers.

**Ours, item by item:**

| Paper's requirement | Todhchai |
|---|---|
| No external schema plus scanner | The schema is Swift. The macro generates the Swift side at compile time; idlc's C headers are **committed**, so a C, Zig or Odin client never runs a generator |
| Hashed identifiers, not order | 64-bit FNV-1a of `protocol.method`, collisions rejected at build time |
| Native 64-bit | All integer widths, naturally aligned |
| 8-byte alignment, zero-copy | 8-byte-aligned bodies; decoded requests are `~Escapable` views into the receive buffer |
| Clean versioning | `@since(n)`, flexible enums and unions, a recorded baseline; idlc fails a breaking change |
| Handle passing | A side array of up to 64 handles, moved with `consuming` |

**Destruction races** are mostly designed out. Every object is its own
channel, so closing it is atomic, and a pending event dies with the
channel (with an epitaph). There is no shared object-id space on one
socket. **One way they come back:** inside a Flatland-style layer tree,
layers and buffers are *ids within a session*. A `released(BufferID)`
event can then cross a client's removal of that buffer. **Fix (small):**
when the protocol is written, ids are client-allocated and never reused
until the server confirms removal. Flatland does this too. A release for
a removed id is defined to be harmless.

**Verdict:** covered. Cap'n Proto and FlatBuffers would bring a
third-party runtime (against principle 29) and nothing we lack. The paper
cites Mir's protobuf episode as a lesson; we have already learned it.

### 6. Split presentation from window management

**Paper:** a minimal presentation engine on DRM/KMS places client buffers
on planes, and a separate session and window-manager process holds policy.
A window-manager crash then keeps clients alive.

**Ours:** half of this is already true. Display is its own service
(`/svc/display`, §10), so mode, planes and the display timeline belong to
the display driver, not the compositor. Radharc owns the scene, input
routing, decorations, move and resize, and policy. The launcher restarts
crashed services and clients reconnect through the SDK (§3).

**Assessment of the full split:**
- *For:* the window manager is the code most likely to change and to
  crash. A crash would no longer cost the user's windows. Alternative
  window managers become clients.
- *Against:* input routing, hit-testing, the move and resize loop, and
  "never show a buffer drawn for the wrong geometry" (F-208) all need the
  scene and the policy together. Splitting them puts IPC on the input path,
  or duplicates the scene. It also costs lines (principle 10).

**R3. Adopt the outcome, not the split: reconnect and replay.** Our SDK
owns the window and its retained layer tree, and the client holds its
buffers as VMOs. When Radharc's channel closes, the SDK waits for the
launcher to restart it, reconnects through the compositor's path in its
namespace, reopens each window with its last
geometry, replays its layer tree, and re-presents the last buffers. The
app gets one `configure` and, perhaps, a frame event late. Arcan does this
(clients survive the server and can migrate). It needs:
- the SDK to keep enough state to replay (it mostly does, for `configure`
  handling);
- view tokens (replicants, embedded dialogs) to be re-established by the
  embedder;
- a test: kill Radharc under the nested-compositor CI run, and check that
  the reference programs keep running.

Window *policy* (placement, tiling rules, snapping) can then move to a
client over the formal `windows` service (R1) later, if it proves worth
it. That gives the paper's split where it is cheap and none where it is
expensive.

### 7. Network transparency

**Paper:** the network should be a native transport, with shared memory
locally and a codec-negotiated stream (H.265, AV1) remotely. Arcan's A12
is the model.

**Ours:** §19 defers remote display "until a dedicated remote-display
design exists".

**Verdict:** keep it deferred, but note two things in §19 now:
- **Nesting gives remote display almost for free.** A Radharc whose
  `/svc/display` is a *remote* display service (one that encodes and sends
  its frames) is a remote desktop. A single window can be forwarded the
  same way, through `capture` (R1) and `inject`. No new compositor
  protocol has to cross the network.
- **A12 is the design to study** when this is scheduled. Its primitives
  are close to ours: X25519 and BLAKE3, which are on our crypto list, and
  ChaCha. The codec is the expensive part. A first version can send
  damage rectangles with a lossless compressor of our own. AV1 and H.265
  wait for hardware codec drivers.

### 8. "Retain DRM/KMS, GBM, syncobj and libinput"

The paper is written for Linux. Each item maps onto something of ours:
KMS is the display driver tiers (§10), GBM and DMA-BUF are the buffer
object plus buffer negotiation, syncobj is the timeline counter. **libinput
is the one we underweight.** Architecture §13 covers keys, deltas, pen,
gamepads and IME. It doesn't cover touchpads: acceleration curves, palm
and thumb detection, tap and clickfinger, gesture recognition, and
per-device quirks. libinput spends most of its size there. **Fix:** add a
touchpad line to §13 and a reference device to the hardware list before
M8. Laptops make this a release blocker. libinput's quirks database may
be usable as data with its license recorded; its code may not
(principle 29).

### 9. The other systems

- **Arcan:** confirms our direction (shared-memory rings, brokered
  capabilities, crash survival). We decline its Lua policy engine. Policy
  is code in Radharc or a `windows` client, in the system's languages.
- **SurfaceFlinger and HWC:** this is our plane-first order, already
  adopted.
- **Redox Orbital:** a scheme-path display service, like our Node tree.
  The paper's criticism (no multi-plane support) is about its maturity,
  not its shape.
- **X11 revival:** not relevant to us.

## Claims to discount

- *"One to two intervals of mandatory latency."* Mature Wayland compositors
  scan out a fullscreen surface directly and latch late. Composition
  latency is a property of an implementation, not of the protocol. Our
  budgets measure the real number (performance.md, input to photon at M8).
- *"Hardware presentation engine as an unprivileged daemon."* Whatever owns
  the planes holds the display. On our system that is a granted
  capability, which is the honest version of the claim.
- *Cap'n Proto "zero runtime overhead," "reading directly from socket
  queues."* Socket and channel reads copy. Zero-copy means decoding in
  place, which we already do.
- *Mir abandoned its protocol for protobuf's speed.* Canonical's reasons
  were largely about the ecosystem. The protobuf costs were real, but they
  were not the whole story.
- Several citations are forum threads, gists, or unrelated pages (a
  package list, a wallpaper engine's notices). Treat the paper as a list of
  questions, not a set of facts.

## Recommendations

| # | Change | Where | Size | When |
|---|---|---|---|---|
| R1 | Privileged compositor services (`capture`, `inject`, `shortcuts`, `observe`, `windows`, `a11y`), one handle each, with grant, indicator, trusted path and marked injection | desktop.md §1 (new subsection), architecture.md §17 | design now; build with reference programs | design before M4; `windows` in M4, the rest by M6 (UI Kit and shell) |
| R2 | Async present honored only on a plane; overlay promotion for windowed games | desktop.md §1 "Game mode", sdk.md §4 | a paragraph | now |
| R3 | Compositor crash survival by SDK reconnect and replay, tested in CI | desktop.md §1, architecture.md §3, performance.md (a test) | moderate, mostly SDK | M4 exit or M6 |
| R4 | Layer and buffer ids client-allocated, never reused before confirmation; release as counter values, never handles | desktop.md §1 "Protocol" | a paragraph | when the protocol is written (M4) |
| R5 | Remote display as nesting over a remote `/svc/display`; study A12 | architecture.md §19 | a paragraph | now; build later |
| R6 | Touchpad handling and libinput's quirks as data | architecture.md §13, hardware list | a paragraph | before M8 |
| R7 | Write down that Wayland core+ excludes shell extensions such as layer-shell | architecture.md §15 | a sentence | now |

Nothing in the paper argues for changing the wire format, the IDL, the
sync model or the scanout order.
