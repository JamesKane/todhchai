# Desktop: compositor, shell and look

The desktop draws on BeOS for structure (Tracker, Deskbar, yellow tabs,
replicants, queries everywhere) and on retro-future cyberpunk for its look.
It is built on Vulkan and puts game latency ahead of effects.

This document follows Scott Jenson's four layers of UX
([research/jenson-desktop-ux.md](research/jenson-desktop-ux.md), decided
2026-10-10): *strategy* (§0: who it is for and what it leaves out),
*structure* (§2 to §5: how windows, files and work are organized), *style*
(§6: the look), on *stuff* (§1: the compositor, protocol and input it all
stands on).

## 0. Strategy

- **For people doing sustained work on one machine**: developers, makers,
  players of games, people who keep and search their own files (music,
  photos, mail). A wide screen and a keyboard are the common case; touch
  works but doesn't lead.
- **The desktop remembers.** Direct manipulation forgets: the clipboard
  overwrites itself and yesterday's context is rebuilt by hand. Taisce's
  attributes, queries and journal let the desktop keep what was gathered
  (the drawer, §3), where things came from (provenance, §3) and what was
  done (the attention history, §3).
- **Additions beside what works.** New structure (the focus area, stashing,
  the drawer, the history) arrives as options next to stacking windows,
  workspaces and the classic clipboard, never by taking them away.
- **Prototype first.** Structural ideas are tried as opt-in prototypes on
  the hosted SDK (Linux, Wayland), small and quick in the manner of Ink &
  Switch, before M8 makes any of them a default.
- **Left out:** a desktop that needs a network account; anything that
  records what the user reads or types; effects that cost latency (§6).
  The place of AI models in this desktop is not yet decided.

## 1. Compositor: Radharc

The compositor is **Radharc** (Irish for "view, scene").

### Protocol: a Flatland-style retained layer tree
- Each client owns a small tree of 2D layers. A layer is a rectangle with
  content: an image (a GPU buffer object), a solid color, or a nested view.
  It also has a clip, an opacity and a 2D affine transform.
- `present(targetTime:)` commits all pending changes atomically. Each image
  carries an acquire fence (a timeline counter value). The compositor returns
  release fences and a **present credit**, so a client can never queue more
  frames than its latency setting allows.
- Release is a **counter value** on the buffer's own timeline, never a
  fence handle per frame (cheaper, and events carry no handles).
- Layer and buffer ids are allocated by the client and never reused until
  the server confirms the removal, so an event crossing a removal is
  harmless. Each object being its own channel removes Wayland's destruction
  races everywhere else; ids inside a session are where they could return.
- **View tokens** let one client embed another's surface. Replicants, the
  file chooser, IME candidate windows and system dialogs drawn inside an app
  (Vita-style) all work this way, out of process.
- The protocol is an `@IPCLibrary` protocol, and its fast path is a shared-memory
  present queue. The Wayland core+ server translates Wayland into this
  protocol. Translation never runs the other way.

### Nesting: the compositor serves what it consumes
Plan 9's rio is a client of the same `/dev/draw`, `/dev/mouse` and
`/dev/cons` files it serves to its windows, so rio runs inside a rio window
with no special code. The Todhchai compositor must have the same property
(principle 26). The protocol therefore needs:
- **A root view from the namespace.** The compositor finds its output
  through `/svc/display` in its own namespace. On real hardware that is the
  display driver; nested, it is a window from the parent compositor.
- **Input complete enough to drive another compositor:** raw key usages,
  unaccelerated pointer deltas, pen and gamepad records, with hardware
  timestamps passed through.
- **Clipboard, drag and drop, and IME as separate services** that a nested
  compositor forwards to its parent. rio passes `snarf`, `kbd` and `screen`
  through in the same way.
- **Configure events with a `configSeq`**, and visibility events, so a
  nested compositor can throttle when its window is hidden. rio's resize
  protocol (rename the window image, then signal through the mouse stream)
  is the thing to avoid: a client that misses the signal fails with
  "old name".
- **Connect specs** in place of rio's attach specs: `connect(.newWindow(...))`
  for an app, and a control-only window-manager handle (rio's `none`) for
  tools such as a taskbar that manage windows without drawing.
- **Press selects, release raises** (decided 2026-10-10, after the
  Macintosh). A click in a background window selects at once but raises
  and focuses the window only when the button comes up without a drag; a
  drag that starts there leaves the stacking alone, so an item can be
  dragged out of a window behind another. Touch does the same.
- **Window control is typed and multi-subscriber.** rio's `wctl` verbs
  (move, resize, top, hide, current, ...) are the right set, but rio lets
  only one reader see window changes, and its own source notes that fan-out
  would be better.

CI runs the compositor inside itself, two levels deep, under the hosted
backend. The same property gives a desktop in a window under hosted mode,
and lets an IDE or terminal host GUI tools in a pane by passing them a
compositor-shaped endpoint (acme does this for its children over
`/mnt/wsys`).

### Privileged services
Wayland isolates every client and leaves capture, synthetic input, global
shortcuts and assistive technology to portals and daemons that each
desktop implements differently. X11 gives them to every client. Radharc
serves each as its own typed protocol on its own channel, a service node
in its tree, so granting one grants nothing else
([research/wayland-alternatives-review.md](research/wayland-alternatives-review.md)):

| Service | Gives | Typical holder |
|---|---|---|
| `capture` | buffer objects for an output, a window or a view subtree, with damage, through the present-queue ring in reverse | recorder, magnifier, remote desktop |
| `inject` | synthetic key, pointer, touch and pen records, entering before or after focus routing | automation, switch access, dwell click |
| `shortcuts` | registered chords, matched and consumed by the compositor; the holder sees no other keys | hotkey tools, push-to-talk |
| `observe` | a read-only input feed (keys with modifiers, pointer position) | screen readers (key echo), on-screen keyboards |
| `windows` | the window list (geometry, focus, workspace, owner signature) with typed `wctl` verbs, multi-subscriber: the control-only handle above | Deskbar, tiling scripts, `hey` |
| `a11y` | every window's accessibility tree (sdk.md §10) in screen coordinates, following focus | screen readers |

- **Grants** work as other direct grants do (architecture §5): the manifest
  asks, the user approves once through the trusted prompt, the grant is a
  recorded attribute, and revoking it closes the channel. A handle is
  already unforgeable, so there are no tokens.
- **Visible while in use.** Deskbar names every holder of an open
  `capture`, `inject` or `observe` channel. The compositor serves them, so
  it knows.
- **Trusted path.** The keyring's confirmation prompt and the login screen
  are secure surfaces: blacked out in `capture` and `a11y` (a screen reader
  reads the prompt over the prompt's own channel), skipped by `observe`,
  and deaf to injected input. Otherwise `inject` could approve its own
  grant.
- **Injected input is marked** with its source. Apps may ignore the mark,
  so accessibility works everywhere; the trusted path refuses it.
- **Nesting:** a nested compositor forwards these to its parent, as it does
  clipboard and IME.

Each one is built against a reference program (principle 8): `windows`
with Deskbar, `capture` with a recorder, `inject` with a dwell-click tool.

### Crash survival
Radharc holds the scene, but each client's SDK holds the same state: its
windows, their last geometry, its retained layer tree and its buffers
(VMOs). When the compositor's channel closes, the launcher restarts
Radharc, and the SDK reconnects, reopens each window, replays its layer
tree and re-presents its last buffers. The app sees one `configure` and
perhaps a late frame. Embedders re-establish their view tokens. The
display mode survives too, since it belongs to the display driver
(architecture §10). CI kills the compositor under the nested run and
checks that the reference programs keep running. Window policy can later
move to a client of `windows` if that proves worth it; input routing and
the move and resize loop stay with the scene.

### Frame scheduling: plane first, latch late
On every vblank, the compositor tries these in order:
1. **Direct scanout.** A fullscreen surface whose buffer suits the display
   (its format, modifier and size are agreed through buffer negotiation) is
   flipped straight onto the primary plane.
2. **Planes.** The game stays on the primary plane. The cursor, HUD and
   notification toasts go on hardware overlay planes.
3. **Composite.** Vulkan composition runs on an async compute queue at high
   global priority. It starts at `vblank − measuredCost − margin` (late
   latching), so input reaches the screen with the least delay.

Before Vulkan is available (driver stage 1 in architecture §10), the
compositor composites on the CPU into the GOP framebuffer, with the same
protocol and the same damage tracking, and without effects. This is also
how the arm64 boards run for a long time, since their GPUs come after AMD.
With a takeover display driver (display tier 2 in architecture §10) the CPU
path still gets real page flips and vblank times, and a fullscreen CPU
surface can be scanned out directly.

The display driver advances a **display-timeline** kernel object from its
vblank interrupt, stamped with the hardware time. On the bare firmware
framebuffer there is no vblank interrupt; the driver advances the timeline
from a timer at the mode's rate and marks it as synthesized, and that mark
reaches clients in present feedback.

The vblank interrupt is routed to a CPU that deep idle won't put out of
reach, and the compositor's latch thread runs under a deadline profile, so
croi keeps its CPU's wake latency inside the frame margin
([croi-requirements.md](croi-requirements.md) §3 item 11). On the Q8B, vsync
landing on a sleeping core cost frames until this was done by hand. The compositor's real-time
thread waits on that object directly, with no message hops. Frame events to
clients carry the next target and the measured present time of the previous
frame (F-101).

### Game mode
- A focused fullscreen game turns off every desktop effect and is scanned out
  directly.
- Tearing is allowed when the client asks (async flip). Only a surface on
  a plane can tear: a composited window's present waits for the next
  latch, and present feedback says so. A focused windowed game is
  promoted to an overlay plane when the hardware allows, so it can tear
  too (Windows' Independent Flip).
- VRR follows the game's present rate, with low-framerate compensation below
  the VRR floor.
- Color transforms use the display engine's degamma, CTM and gamma LUTs
  instead of a shader pass.
- **Upscaling:** a lower-resolution swapchain can be scaled by the display
  engine, or by our own upscaling compute pass (an FSR-class design written
  from published descriptions, not from FSR's code) when the hardware
  scaler can't.
- The overlay (FPS, frame-time graph, latency) is a hardware plane, so it
  never breaks direct scanout.

### HDR and color
Composition runs in linear FP16 (scRGB), with PQ/HLG output when the display
supports it. Theme colors are given in nits, so neon glow uses HDR headroom on
HDR displays and is tone-mapped down on SDR.

### Visibility and power
- The server computes each window's visibility: visible, partial, occluded or
  hidden. Occluded and hidden windows get a throttled frame clock (F-209).
- An idle desktop does zero work per frame. Composition happens only when
  something is damaged.

## 2. Window management
- **Decorations belong to the server.** They draw the yellow-tab lineage as a
  neon tab, and an app can claim the title strip (see [sdk.md](sdk.md) §4).
- Move, resize and snapping run in the server. Clients get `configure` events
  with a `configSeq`, and the compositor never shows a buffer drawn for the
  wrong geometry (F-208).
- **Workspaces** follow the BeOS model: per-workspace resolution and
  wallpaper, with Deskbar switching.
- **Stacking:** stacking and tiling are both supported, and tiling is optional
  per workspace. Tab-stacking (Haiku stack-and-tile) lets windows share one
  title tab.
- **A focus area and a live periphery** (decided 2026-10-10), a third mode
  per workspace beside stacking and tiling, for wide outputs. The middle of
  the screen (about half its width) holds the windows being worked in; the
  sides hold the others, scaled down, live and usable where they are.
  Pushing a window aside (a drag or a shake) makes room. Workspaces stay,
  but are no longer the main answer to too many windows.
- **Stashing** (decided 2026-10-10). A window dragged to an edge is
  stashed: its `configure` carries a compact size class, and the app may
  reflow into a minimal form (a music player into its play button) or let
  the server show it scaled ([sdk.md](sdk.md) §4). Stashed windows are laid
  out with the replicants, and come back at full size with a drag or a
  click.

## 3. Shell

All shell apps use the public SDK and UI Kit.

| App | Role | Be heritage | New |
|---|---|---|---|
| **Tracker** | file manager and desktop | attribute columns, queries as folders, live query windows, file types (MIME) | async listings with millions of entries; query builder with v2 syntax; previews through translators; browse snapshots by date |
| **Deskbar** | app launcher, running apps, tray | replicant tray | replicants run out of process; system status (CPU, GPU, audio latency, frame pacing) as built-in gauges |
| **Terminal** | console | — | GPU glyph atlas, refterm-class speed, inline images, and a `/svc/self` inspector |
| **Inspector** | system visibility | — | live processes, threads, wait reasons, memory (reserved vs committed), handles, IPC graph, GPU queues; launches the tracer |
| **Preferences** | settings | Be preference apps | every setting is a file with attributes, and Terminal can change it |
| **People / Mail** | contacts and mail as files with attributes | BeOS People and Mail | the same pattern, as showcases for the Storage Kit |

**Scripting** has three parts:
1. **Addressable state.** An app's properties can be read and set by path
   through a typed IPC schema: the BMessage-scripting (`hey`) model with
   real types. A `hey`-style command-line tool is generated from the
   schema. The UI Kit gives every app a basic schema (windows, views,
   menus), and Tracker, Deskbar and the Inspector publish rich ones.
2. **An intent stream.** An app publishes the user's intents (commands,
   opens, selections) as a subscribable stream.
3. **Claim and decline**, from acme's `event` file. An outside process can
   claim an app's intents. For each one it either handles it or declines
   it, and a declined intent runs the app's default. This lets someone add
   a Tracker context-menu action, or turn an editor buffer into a REPL,
   without in-process plugins. Unlike acme, claiming is an explicit call
   with a lease: if the claimer dies, the app goes back to its defaults,
   and more than one observer can watch the stream.

**Memory** (decided 2026-10-10; prototypes first, §0):
- **The drawer.** The clipboard service keeps its history as files with
  attributes: `Clip:Source` (the app's signature), `Clip:Origin` (an entry
  reference or URL) and `Clip:Time`. Any document can have a drawer: clips
  linked to it by attribute, shown beside it, kept after it closes, found
  by query. Text, images, files and web content can be dropped in. Limits
  on size and age are per user.
- **Provenance.** A file made by save, download, paste or a translator
  records where it came from (`sys:origin`, `sys:origin-app`;
  [filesystem.md](filesystem.md) §6). Tracker shows it and can query by
  it, and the drawer and the history link back through it.
- **The attention history**, opt-in. A small service folds the intent
  stream (above) and the router's messages into a timeline of signals:
  opens, saves, how long something was in front, that a copy or paste
  happened. It never records content (not what was copied, not what a page
  said), keeps everything in the user's own Taisce volume, is off until
  turned on, is listed in the Inspector while it runs, and is cleared with
  one command. Tracker shows the timeline, each entry linked to its file
  or window.

## 4. The router (plumber)

Plan 9's plumber is a small service (about 2,600 lines) that routes "open
this" messages between apps using rules. Clicking `main.c:42` anywhere
opens an editor at that line, and a URL goes to the browser. Todhchai keeps
it as the **router**, a tier 0 service.

- **Message:** source app signature, optional destination port, working
  directory, MIME type, attributes, and a payload. The payload is inline
  bytes or a handle: a VMO for large data, a file handle, or an entry
  reference (node id plus volume), so Tracker can route a file without a
  path race. The router authenticates the source from the sending
  process, which Plan 9 doesn't.
- **Ports:** an app's manifest declares the ports it serves (`edit`,
  `image`, `web`, ...) and the MIME types it handles. Messages arrive as
  events on the app's loop, so there's no dedicated thread (acme needs a
  separate process just to read the plumber).
- **Delivery** follows the plumber:
  - every listener on a port gets a copy;
  - with no listener, a rule can start the app;
  - with "start and hold", the message waits until the started app opens
    its port, which removes a launch race.
- **Rules** keep the plumber's readable text format, reloaded when the rules
  file changes. They add MIME wildcards (`type is image/*`), content
  sniffing through translators, attribute matching (`attr Audio:Artist is
  ...`), and Taisce queries. A rule starts an app by signature with a typed
  argument array. It never runs a shell command.
- **Uses:**
  - **Tracker:** "Open" is a routed message carrying the MIME type and an
    entry reference.
  - **Terminal:** a right-click routes the clicked text with its offset,
    so `file.swift:120:7` in compiler output opens the editor at that spot.
  - **Debugger:** routes `file:line`; editors route `breakpoint` to debugd.
  - **Crashes:** debugd routes `type=todhchai/crash`.
  - **Mail and People:** handle `mailto:`.

## 5. Replicants and translators
- A **replicant** is a small out-of-process program that publishes a view
  token. Deskbar and the desktop embed it. A crash takes down only the
  replicant.
- **Translators** are sandboxed processes that convert formats into canonical
  intermediates: image to bitmap, audio to PCM, document to text and
  attributes. The UI Kit (image loading), the Media Kit and the indexer
  (content extraction) all use them. Installing a translator teaches every app
  the new format, as on BeOS.

## 6. The look: retro-future cyberpunk

**References:** the BeOS yellow tab, Blade Runner's amber and teal CRTs, the
Alien Nostromo terminals, Ghost in the Shell's wireframe and readouts,
eDEX-UI, Cyberpunk 2077's red and cyan with angled cuts, Tron: Legacy.

### Design tokens (default "Neon Tab" theme)

| Token | Value | Use |
|---|---|---|
| `bg.0` | `#0a0a12` | desktop, window body |
| `bg.1` | `#12121e` | panels |
| `ink` | `#d8e1ff` | primary text |
| `neon.cyan` | `#00e5ff` (≈ 400 nits on HDR) | focus, links, active tab |
| `neon.magenta` | `#ff2bd6` | alerts, selection |
| `neon.amber` | `#ffb000` | the "Be yellow" tab, warnings |
| `phosphor` | `#39ff88` | terminal default |
| `shape.cut` | 8 px chamfer | panel corners |
| `glow.radius` | 6 px (SDF) | focused chrome |

Fonts: a monospace with box-drawing coverage for terminal and readouts, and a
condensed sans for UI. Fonts are data under principle 29, so openly licensed
fonts can be used, with their license and provenance recorded. A typeface
drawn for Todhchai can come later. The rasterizer and shaper are ours.

### How it is rendered cheaply
- All chrome is **analytic SDF shapes** drawn by one fragment shader per quad:
  chamfered or rounded rectangles, borders, cut corners. Glow is the same SDF,
  sampled past the edge, so it costs almost nothing.
- **Text** uses MSDF atlases, so outlines and glow come from one sample.
- **Bloom** is only for the HDR desktop layer. It runs at quarter resolution
  with a dual-Kawase pyramid and is cached until damaged.
- **CRT/scanline/phosphor** is an optional final pass: scanlines, aperture
  grille, slight barrel distortion, temporal phosphor decay, chromatic offset.
  It turns off automatically under direct scanout or game mode, and when the
  compositor's frame budget is short.
- **Glitch effects** fire only on events (errors, notifications), last less
  than 200 ms, and are never continuous.
- **Accessibility theme:** high contrast, no glow animation, no flicker, no
  chromatic aberration, larger type. It is one switch, and the first-boot
  setup offers it.

### Budget
Desktop composition with all effects on must take under 1.5 ms of GPU time at
4K on the reference GPU and under 0.3 ms with effects off. The compositor's
latch thread must never miss a vblank because of effects. Effects are dropped
first.
