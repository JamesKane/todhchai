# Plan 9 (9front) desktop lessons for Todhchai

Source tree: `/home/jkane/Projects/OS/9front`. All paths below are relative to that root. Line numbers come from the tree as checked out. Todhchai context: architecture.md (channels, ports, per-process namespaces, Swift IDL) and desktop.md (Vulkan compositor, Flatland-style layer tree, view tokens, present credits).

Size summary (lines of C):

| Component | Lines |
|---|---|
| rio (`sys/src/cmd/rio/*.[ch]`) | 6,382 (wind.c 1,849, rio.c 1,352, xfid.c 916, fsys.c 701, wctl.c 500) |
| devdraw (`sys/src/9/port/devdraw.c`) | 2,103 |
| libmemdraw / libmemlayer / libdraw | 5,963 / 1,205 / 6,560 |
| plumber (`sys/src/cmd/plumb`) + libplumb | 2,608 + 556 |
| acme (all) / acme fsys.c+xfid.c | 14,546 / 1,849 |
| devproc.c | 1,696 |
| acid / libmach / `sys/lib/acid/port` | 5,601 / 20,405 / 719 |

---

## 1. rio: a window system that is a file server

### What it serves
rio has one dirtab (`sys/src/cmd/rio/fsys.c:22-41`). Global files are `screen`, `snarf`, `wctl`, `kbdtap`, and `wsys/` (a directory holding every window by id). Per-window files are `cons`, `consctl`, `cursor`, `winid`, `winname`, `label`, `kbd`, `mouse`, `text`, `wdir` and `window`. Every 9P request becomes an `Xfid` that runs in its own libthread thread (`xfid.c:37` `xfidallocthread`). One proc reads 9P off the pipe (`fsys.c:150-198` `filsysproc`).

- **`/dev/mouse`**: each read blocks on `w->mouseread` and returns a 49-byte record, `m x y buttons msec`. If the window was reshaped since the last read, the record starts with `r` instead (`xfid.c:784-816`, `c = 'r'` at `:810`). The window thread queues button transitions in a ring and discards the whole queue when it fills ("discard frantic clicking", `wind.c:1658-1671`).
- **`/dev/cons` and `/dev/kbd`**: reads go through `alt` on {data, `w->gone`, `x->flushc`}, so a deleted window or a 9P `Tflush` unblocks the reader (`xfid.c:704-740`). The kbd format is `k`/`K`/`c`-prefixed strings, NUL-separated (`wind.c:1610-1640`).
- **Exclusive opens**: `consctl`, `kbd`, `mouse` and a readable `wctl` can each be open only once (`xfid.c:262-310`). A comment there admits that fan-out for `wctl` reads "would be much nicer" but rio "just isn't structured for that" (`xfid.c:297-305`).
- **`/dev/wctl` read**: blocks until state changes, then returns `minx miny maxx maxy current|notcurrent visible|hidden` (`wind.c:1753-1761`; `xfid.c:681-697`). With no window (`none` attach), it returns the screen rect and `nowindow`.
- **`/dev/window` and `/dev/screen`**: a 5×12-byte image header (chan and rect) followed by raw pixels (`xfid.c:871-905`). `lp /dev/wsys/123/window` prints a window (`sys/man/4/rio:400`).
- **`/dev/winname`**: the *name of a devdraw image*, `window.<id>.<n>` (`wind.c:330-347`). This is how a client finds its pixels. See §2.

### How a client's namespace gets these files
1. At startup rio creates a pipe and posts the client end as `/srv/rio.<user>.<pid>`, then sets `$wsys` to that path (`fsys.c:88-100, 137-138`).
2. When rio starts a window's shell, `winshell` runs `rfork(RFNAMEG|RFFDG|RFENVG)`, which gives the child a private namespace, and calls `filsysmount(filsys, w->id)` (`wind.c:1823-1824`). That function mounts the pipe on `/mnt/wsys` with **the window id as the attach spec**, then binds `/mnt/wsys` *before* `/dev` (`fsys.c:201-215`). The child then reopens fd 0 as `/dev/cons` (`wind.c:1829-1830`). The `/dev/cons` it gets is rio's, not the kernel's.
3. `xfidattach` parses the attach spec (`xfid.c:168-228`):
   - `N pid,minx,miny,maxx,maxy` is the old syntax.
   - `new <wctl args>` runs the same `parsewctl` as `wctl` writes, then allocates a window.
   - `none` attaches with no window, for control.
   - A number re-attaches to an existing window.
   With `-hide`, the window is created as an offscreen `allocimage` instead of a layer (`xfid.c:206-209`).
4. `newwindow()` in libdraw is the whole client side. It reopens `$wsys`, forks the namespace, unmounts the old window, and mounts with `"new <args>"` (`sys/src/libdraw/newwindow.c:7-38`). The man page example is `mount $wsys /tmp 'new -r 0 0 128 64 -pid '$pid` (`sys/man/4/rio:385`).

### wctl command set
Commands (`wctl.c:19-49`): `new resize move scroll noscroll set top bottom current hide unhide delete`. Parameters (`wctl.c:51-80`): `-cd -dx -dy -hide -id -maxx -maxy -minx -miny -pid -r -scroll -noscroll`. `-id` makes a command act on another window (`wctl.c:470-477`). Commands from `top` onward are refused while a mouse button is held. `resize` and `move` are refused unless the target is the current window: `"window not current"` (`wctl.c:377-380`). Each command becomes a `Wctlmesg` (`Reshaped`, `Topped`, `Repaint`, `Deleted`, …) sent to the window's thread (`wind.c:1368-1440`).

### Resize protocol
- rio allocates a new layer with `allocwindow(wscreen, r, Refbackup, …)` and sends `Reshaped` (`wctl.c:369-393`).
- `wresize` sets `w->resized = TRUE` and calls `wsetname`. That **renames** the image to `window.<id>.<namecount++>` (`wind.c:350-382, 330-347`).
- The client's next mouse read returns `r`. libdraw's mouse proc turns that into a message on `mc->resizec` (`libdraw/mouse.c:67-71`). The application calls `getwindow(display, Refnone)` (`libdraw/init.c:185-190`).
- `gengetwindow` then reads `/dev/winname` and calls `namedimage()`. If the name changed between the read and the lookup, it retries (`init.c:126-145`). It frees the old screen, runs `allocscreen` on the window image, and runs `_allocwindow` inset by `Borderwidth` (`init.c:160-171`).
- The old name is versioned. Any draw on an image obtained under a stale name fails with `Eoldname`, "named image no longer valid" (`devdraw.c:184, 455-479`). That is how a client that misses the resize is caught.

### Hidden and occluded windows
- **Occluded**: rio's windows are `Refbackup` layers. The *kernel* keeps a backing store for the obscured parts, so a client never repaints because of overlap (`libmemlayer/lalloc.c:32-42`; `layerop.c:53-114` writes obscured parts into `l->save`).
- **Hidden**: `whide` swaps the window's layer for an offscreen `allocimage` and sends `Reshaped` with `ZR` (`rio.c:1132-1152`). The client keeps drawing into an ordinary image and doesn't know it is hidden, except through `wctl` reading `hidden`. Unhide allocates a fresh layer and copies the contents back (`rio.c:1154-1175`). `Repaint` and `Refresh` are skipped when `Dx(screenr)<=0` (`wind.c:1416-1424`). rio never throttles a hidden client.

### Nesting: rio inside rio
rio is an ordinary libdraw client.
- It calls `geninitdraw(…, "rio", nil, Refnone)` (`rio.c:181`), which follows the outer `/dev/winname`. It calls `initmouse` on the outer `/dev/mouse` (`rio.c:192`) and builds its own `Screen` on its window with `allocscreen(screen, background, 0)` (`rio.c:203`).
- Its `mousethread` `alt`s on `mousectl->resizec` (`rio.c:533-543`). `resized()` calls `getwindow`, rebuilds `wscreen`, and **rescales every child window proportionally**, sending each a `Reshaped` (`rio.c:651-697`). The resize cascades down the tree.
- Inner rio *passes some files through* to the outer instance instead of serving them. `skipdir` hides `snarf` when an outer `/dev/snarf` exists, `screen` when an outer `/dev/screen` exists, and `kbd` unless it is serving its own (`fsys.c:326-336`; `rio.c:178-179`). Because rio's mount is a union `MBEFORE` `/dev`, a walk to a skipped name falls through to the parent's file. The man page states that a nested rio uses the parent's snarf buffer (`sys/man/4/rio:178-182`).
- Nesting works because rio consumes exactly the interface it provides: `/dev/draw` (through `winname`), `/dev/mouse`, `/dev/cons` and `/dev/kbd`, `/dev/snarf`, and `wctl`.

**For Todhchai:**
- **Adopt: the compositor serves the same protocol it consumes.** A Todhchai compositor running as a client must be able to get a `Surface` or view from its parent, receive input from its parent, and re-export a full `Compositor` protocol to its own children. In concrete terms the protocol needs:
  - (a) a way to obtain "my root view" from the environment, the equivalent of `$wsys` plus attach. Use a `/svc/todhchai.display.Compositor` entry in the namespace and have the launcher choose which compositor instance it points to.
  - (b) per-view input delivery that is complete enough to drive another compositor: raw pointer with all buttons and timestamps, raw keys up and down (like `/dev/kbd`, not cooked text), and focus enter and leave.
  - (c) a configure event that carries the new size *and* a `configSeq`, already in desktop.md. This is the typed version of the `r` mouse message plus `getwindow`.
  - (d) clipboard, drag and drop, and IME as *separate services*, so a nested compositor can forward them instead of owning them. This is the `skipdir` pass-through, made explicit by the launcher putting the parent's `/svc/clipboard` in the child's namespace.
  - (e) visibility state (visible, partial, occluded, hidden) as an event the nested compositor can both read and forward.
  Make nesting a test case: run the compositor as a client of itself, the way Wayland compositors run nested for development.
- **Adopt: the attach spec as a creation argument.** "Connect and create a window with these parameters" as one call (`mount … 'new -r …'`) is good. Mirror it as `Compositor.connect(spec: WindowSpec) -> (View, InputChannel)`.
- **Adopt: a `none` attach, a control-only handle** for scripts that move or tile windows. Expose it as a separate `WindowManagerControl` protocol, granted by manifest.
- **Adapt: wctl.** Its verbs (`new`, `resize`, `move`, `top`, `bottom`, `current`, `hide`, `unhide`, `delete`, with `-id`) are a good minimal WM scripting surface. Make it typed IPC. Make its state *fan-out observable*: every subscriber gets every change, unlike rio's single-reader `wctl` (`xfid.c:297-305`).
- **Avoid: renaming the image to signal resize, and retry loops** (`init.c:126-145`). Use buffer generations and `configSeq`. **Avoid server-side backing store per window** (`Refbackup`). Each client already owns retained GPU buffers, which is a better design. **Avoid** leaving hidden clients unthrottled. desktop.md's throttled frame clock is right.

---

## 2. devdraw: a server-side image protocol in the kernel

**Model.** Each client opens `/dev/draw/new` and gets `/dev/draw/<n>/{ctl,data,colormap,refresh}` (`devdraw.c:18-25, 264-301, 996-1030`). Opening `ctl` installs the screen as image id 0 under its public name (`devdraw.c:1010-1030`). The client writes batches of one-letter commands to `data`. libdraw buffers them in `d->buf`, and `flushimage(d, 1)` appends `'v'` and writes the batch (`libdraw/init.c:434-446`). Images, fonts (glyph caches) and screens live **on the server**, named by 32-bit ids that the client chooses.

**Key messages** (in `drawmesg`, `devdraw.c:1468+`):
- `b id screenid refresh chan repl R clipR color`: allocate. With `screenid != 0` this allocates a **layer (window)** on a screen, with refresh method `Refbackup` (kernel save area), `Refnone` (`memlnorefresh`) or `Refmesg` (queue damage for the client) (`devdraw.c:1503-1567`).
- `A id imageid fillid public`: make an image into a **Screen** that layers can be allocated on. `public` lets other clients use it (`devdraw.c:1573-1587`).
- `S id chan`: attach to a public screen (`devdraw.c:~1925-1938`).
- `N id in name`: publish or unpublish an image under a global name (`devdraw.c:1760-1782`; `drawaddname` `:737-757` bumps a global `vers`).
- `n id name`: import a named image into this client's id space (`devdraw.c:1736-1757`). This is how a client gets the window rio made for it.
- `t top n ids…`: restack layers. `o`: move a layer.
- `d` (draw with Porter-Duff op), `s`/`x` (string from server glyph cache), `r` (read pixels back).
- `w` (affine warp, a 9front addition, `devdraw.c:2019`).
- `v`: flush (`devdraw.c:2012-2016`).

**Layers.** A `Memlayer` holds `screenr`, `delta`, `front` and `rear` pointers, `save`, and `refreshfn` (`sys/include/memlayer.h:15-26`). When `refreshfn` is nil, `memlalloc` allocates a full save image (`libmemlayer/lalloc.c:32-42`). Drawing to an obscured region is split by `_memlayerop`: visible parts go to the screen, covered parts go to `save` (`layerop.c:53-114`).
- With `Refmesg`, exposed rectangles are merged per image in `drawrefresh` (`devdraw.c:332-357`). The client reads them from `/dev/draw/n/refresh` as `id minx miny maxx maxy` records, and that read blocks (`devdraw.c:1169-1200`).
- Layers nest: a window image can itself carry a Screen. That is exactly what each client does to its rio window in `gengetwindow` (`init.c:160-171`).

**How the WM allocates for clients.** rio calls `allocwindow(wscreen, r, Refbackup, DNofill)` (`xfid.c:209`) and then `nameimage(w->i, "window.id.n", 1)` (`wind.c:337`). The client imports the image with `n`, puts its own `A` screen on it, and allocates a `b` layer inset by the border. rio never touches client pixels again. The kernel arbitrates.

**Flush model.** `'v'` only matters on soft screens, where it copies `flushrect` to hardware (`devdraw.c:423-428`). `addflush` merges damage rectangles heuristically (`devdraw.c:359-400`). Draws land on the shared framebuffer immediately. There is no per-client atomic commit, no vsync, and no frame timing. One global `drawlock` QLock serialises every client (`devdraw.c:153, 189-203`).

**What is elegant:**
- (a) Retained, server-side objects with client-chosen ids. The command stream batches well over a network (drawterm and cpu work because of this).
- (b) Global *names* as the capability-ish handoff between processes. That is precisely a view token.
- (c) Screens and layers as one recursive abstraction, so a WM is just a client.
- (d) Stale-name detection by version.

**What is dated:**
- Pixel ops run on the CPU, inside the kernel, under one lock.
- There is no buffer sharing, no fences, no present timing, no color management, and no atomicity. Clients draw straight onto shared layers, so a partially drawn frame is visible.
- Names are a flat global string namespace, a weak capability that any client can guess.
- The backing store doubles memory.
- Fonts are rasterised client-side and uploaded as bitmaps.

**For Todhchai:**
- **Adopt** the recursion. A view is both something you put content in and something that can host child views. Flatland's nested-view layer content is this.
- **Adopt** retained, client-named object ids in the protocol (`LayerID` and `BufferID` chosen by the client, so no round trip per allocation), with batch submission and one commit.
- **Adapt** `nameimage` and `namedimage` into **unguessable view-token handles** (eventpair or channel endpoints) passed over IPC instead of global strings.
- **Avoid** server-side rasterisation, kernel-resident graphics, a global lock, and `Refbackup` save areas. The compositor retains client buffers. Occlusion only throttles the frame clock.
- **Keep one idea from `Refmesg`**: for software-rendered or remote clients, the compositor may tell a client *which rectangles* need content (damage hints), but never require repaint for correctness.

---

## 3. The plumber

**Message** (`sys/include/plumb.h:18-33`): `src`, `dst`, `wdir`, `type`, `attr` (a list of name=value pairs), `ndata`, `data`. On the wire it is newline-separated text fields followed by `ndata` raw bytes (`sys/src/libplumb/mesg.c:131-166`). The data can be binary even though the header is text.

**File interface.**
- The plumber posts `/srv/plumb.<user>.<pid>` and mounts it on `/mnt/plumb` (`cmd/plumb/fsys.c:223-234`).
- Fixed files are `rules` (readable, and writable at run time, which replaces the rule set) and `send`, which is write-only (`fsys.c:96-97, 743, 957`). Each `plumb to <port>` mentioned in the rules becomes a readable file, a **port**.
- A write to `send` tries each ruleset in order, and the first `matchruleset` hit wins (`fsys.c:906-916`). Otherwise a message with an explicit `dst` is delivered directly.
- `dispose` (`fsys.c:537-570`):
  - If the port has readers, the message is queued to *every* open fid. This is fan-out (`queuesend`, `fsys.c:350-375`).
  - If no one has it open, `startup` runs the rule's `plumb start` command (`match.c:431-455`).
  - For `plumb client`, it starts the program **and holds the message until the client opens the port** (`hold`, `fsys.c:506`).

**Rule language** (`rules.c:47-69`). Objects are `arg attr data dst plumb src type wdir`. Verbs are `add client delete is isdir isfile matches set start to`, plus `include`. Each rule is a block of patterns followed by actions. Captured `$0..$9`, `$file` and `$dir` (set by `isfile` and `isdir`, `match.c:124-175, 272-274`) feed into later lines. Examples from `sys/lib/plumb/basic`:
- URLs: `data matches 'https?://…'` → `plumb to web`, `plumb client window $browser` (`:11-14`).
- `file:line` goes to the editor: match, then `arg isfile $1`, `data set $file`, `attr add addr=$3`, `plumb to edit` (`:71-77`).
- `.h` files are looked up in `/sys/include` (`:80-86`).
- `man(1)` references are synthesised into a `man` command (`:105-107`).

The `click=` attribute lets the sender pass the whole line plus the click offset, and the rule extracts the token (`sys/man/6/plumb:198-233`; acme sends it at `cmd/acme/look.c:114`).

**Receivers.**
- acme opens port `edit` and runs a dedicated `plumbproc` (`cmd/acme/acme.c:187-192, 350`).
- samterm opens `edit` (`cmd/samterm/plan9.c:228-229`).
- page opens `image` (`cmd/page.c:1674`). mothra opens `web` (`cmd/mothra/mothra.c:336`).
- Senders write to `send`, as acme and mothra do (`mothra.c:1221`).

The whole service is about 3.2k lines.

**For Todhchai.** Build a **`todhchai.plumb.Router` service** (Tier 0, a few thousand lines of Swift):
- **Message**: `struct PlumbMessage { src: AppSignature; dst: PortName?; wdir: Path; type: MIMEType; attrs: [Attr]; data: Payload }`. `Payload` is inline bytes *or* a handle: a VMO for large data, a file handle, or an entry ref (node id plus volume) so Tracker can plumb a file without a path race. Handles move with `consuming`.
- **Ports as typed endpoints**: an app's manifest declares `plumb.ports: ["edit", "image"]` and the MIME types it handles. The app receives a `PlumbPort` channel on its loop's port. It has no dedicated thread, so it avoids acme's `plumbproc`. Keep fan-out, start-if-absent, and **hold-until-client-connects**, because that last one removes a launch race.
- **Rules**: keep the textual block language, which is readable and hot-reloadable by writing `rules`. Add `type is image/*` with MIME wildcards, `sniff` (ask the translator or indexer for a MIME type), `attr is`, and `query` (match against BeFS attributes). Compile regexes once and run them in the router. Rules live in files with attributes, so Preferences and Terminal can edit them.
- **Integration**:
  - **Terminal** plumbs on right click with a `click` offset, so `file.swift:120:7` in compiler output opens the editor at that line.
  - **Tracker** "Open" is a plumb with `type = MIME` and an entry ref, which replaces a separate preferred-app table, or is backed by it.
  - **The debugger** plumbs `pc=0x…` or `file:line`, and the editor plumbs `breakpoint` to `debugd`.
  - **Crash reports**: debugd plumbs `type=todhchai/crash`.
  - **Mail and People** plumb `mailto:`.
- **Avoid**: string-typed everything, a single global `send` with no sender identity (authenticate `src` from the channel's process koid), and rules that run arbitrary shell. `plumb start` should name an app signature, with arguments passed as a typed array.

---

## 4. acme's file-server interface

**Layout.** Top level (`cmd/acme/fsys.c:64-73`): `cons`, `consctl`, `draw` (mode 0 and empty, "to suppress graphics progs started in acme"), `editout`, `index`, `label`, `log`, `new/`. Per window `n/` (`fsys.c:76-91`): `addr`, `body` (append-only), `ctl`, `data`, `editout`, `errors`, `event`, `rdsel`, `wrsel`, `tag`, `xdata`.

**Namespace trick.** Commands run from acme get acme's fs mounted on `/mnt/acme`, **bound over `/mnt/wsys`** and **before `/dev`** (`fsys.c:253-267`). So `win` and Mail open `/mnt/wsys/new/ctl` (`acme/bin/source/win/win.c:14`; `cmd/upas/Mail/win.c:136`). acme is the "window system" for its children, just as rio is.

**Semantics.**
- `addr` takes a sam address expression. `data` reads and writes at that address. `xdata` is the same but stops at the address end.
- `ctl` accepts `lock unlock clean dirty show name font dump dumpdir delete del get put dot=addr addr=dot limit=addr mark nomark menu nomenu scroll noscroll cleartag scratch` (`xfid.c:609-793`). Reading `ctl` returns window id, lengths, dirty flag, width and font (`wind.c:660`).
- **`event`** is the extension hook (`sys/man/4/acme:364-460`). Each record is `<origin E|F|K|M><type D|d|I|i|L|l|X|x> q0 q1 flag n text\n`.
  - While any process holds `event` open, button-2 (execute) and button-3 (look) actions are **not performed** by acme. They are reported instead (`look.c:34`, `exec.c:153`; `winevent` drops events when nobody listens, `wind.c:671-678`).
  - The client decides. To get the default behaviour, it **writes the event back** and acme performs it as if no one had intercepted it (man page, flag bit 1).
  - Text over 256 chars is elided, and the client reads it from `data`.

This is how Mail makes `Reply`, `Delmesg` and so on into commands: it reads `event`, handles its own verbs, and writes everything else back. It writes message bodies through `/mnt/acme/%d/body` and `xdata` (`cmd/upas/Mail/comp.c:52, 183`). `win` turns a window into a terminal. External tools (`acme/bin`: `Mail`, `win`, `adiff`, `agrep`, …) need no plugin API. The total extension interface is the 1,849 lines of fsys.c and xfid.c.

**For Todhchai.**
- **Adopt the interception-with-default-fallthrough pattern.** An app's scripting protocol should allow:
  - (a) addressable state: get and set properties by path, as BMessage `hey` already plans;
  - (b) a **subscribable event stream** of user intents (commands, opens, selections);
  - (c) **claim and decline**: while an external agent holds the intent stream, the app defers execution. For each intent the agent either handles it or returns it, and the app then runs its default.

  This makes "extend Tracker with a context-menu action" or "turn an editor buffer into a REPL" possible without in-process plugins. It also matches Todhchai's out-of-process replicant philosophy.
- **Adopt "the host is the window system for its children."** The UI Kit should let an app host child views (view tokens) *and* export a `Compositor`-shaped endpoint into a child's namespace. Then a terminal or IDE can run GUI tools inside a pane, and acme's `draw` suppression becomes a manifest choice.
- **Adapt the text formats into IDL types.** Keep a `hey`-style text CLI generated from the IDL, so the shell scripting experience survives.
- **Avoid** the single-reader `event` and its implicit side effect (opening a file changes app behaviour). Make "claim intents" an explicit call with a lease, and fall back to defaults if the claiming process dies.

---

## 5. /proc, notes and acid

**/proc/n** (`devproc.c:89-112`): `args ctl fd fpregs kfpregs kregs mem note notefpregs noteid notepg ns ppid proc regs segment status text wait profile syscall watchpt`.
- `ctl` verbs (`devproc.c:116-146`) include `close`, `closefiles`, `kill`, `hang` (stop at the next exec), `nohang`, `stop`, `start`, `startstop`, `waitstop`, `startsyscall`, `pri`, `wired`, `private`, `profile`, `trace`, `interrupt` and `nointerrupt`, plus real-time `period`, `deadline`, `cost`, `sporadic`, `admit`, `expel`, and `event`.
- `mem` writes require the process to be `Stopped` (`devproc.c:1216-1219`). `regs` writes go through `p->dbgreg` (`:1222-1229`).
- `ns` renders the namespace as replayable `bind` and `mount` lines (`devproc.c:1101-1121`).
- `procstopwait` makes `stop` synchronous (`devproc.c:1344-1371`).
- A process that faults becomes **Broken** and stays in memory for post-mortem attach. The kernel keeps the last 4 (`proc.c:1184-1205`). No core files are written.

**Notes vs signals.** A note is a string up to `ERRMAX`, such as `interrupt`, `hangup`, `sys: trap: fault read addr=…`, or any user text. Writing `/proc/n/note` calls `postnote` (`devproc.c:1260-1266`), and `notepg` sends to a whole note group. The queue holds `NNOTE = 5` (`portdat.h:656`). When it is full, **the note is dropped** (`pushnote`, `proc.c:1126-1142`). System notes flush pending ones if the process has no handler. A handler runs with its own `notefpregs` and returns through `noted()`. A debugger reading `/proc/n/note` consumes notes (`devproc.c:1143`; acid's `notes()` at `cmd/acid/proc.c:104-130`).

Notes are better than signals in three ways: they are text, they are extensible, and they carry their reason. They keep the same flaw: asynchronous interruption of arbitrary code. libthread has to tiptoe around it (`iointerrupt` writes `interrupt` to `/proc/self/ctl`, `libthread/iocall.c:15-24`).

**acid.**
- To debug a new program, `nproc` forks and calls `rfork(RFNAMEG|RFNOTEG)`, writes `hang` to its own ctl, and execs. The parent sends `waitstop` (`cmd/acid/proc.c:61-100`).
- acid reads memory through `/proc/n/mem` (`proc.c:37`) and registers and segments through libmach (`libmach/map.c:57, 102, 111`), and controls the process with `ctl`.
- Because it is all files, **remote debugging is just namespace**: `import` a CPU server's `/proc`, or `srvfs broke /mnt/term/proc` to publish a broken process for someone else (`sys/man/4/exportfs:140-151`). `rdbfs(4)` serves `/proc/n` over a serial line for a remote kernel or board.
- libmach is cross-architecture. With `-m`, an amd64 acid debugs an arm64 process. `-k` debugs kernel state.
- The debugger's "UI" is an interpreted language plus `sys/lib/acid/port` (719 lines). acme integration lives in `sys/lib/acid/acme` and `/acme/acid`.

**For Todhchai:**
- **Adopt** debug-as-a-protocol with *location transparency*. `debugd`'s attach, threads, memory, registers, breakpoints and events go over a channel, so a remote debugger is just a forwarded channel. Expose `/svc/debug/<koid>` in a namespace, and provide a `debug-proxy` that tunnels over the network or serial (the `rdbfs` analogue) for bring-up of croi on boards.
- **Adopt** `hang`, as "start suspended" in the process-creation API. **Adopt** *Broken retention*: keep the last N crashed processes suspended with their address spaces for a bounded time, so a debugger can attach post-mortem, and also write a minidump. **Adopt** a readable namespace dump (`/proc/n/ns`) for the Inspector.
- **Adapt notes into exceptions-on-a-port**, not async handlers. Faults go to a debugger or exception channel, as in Zircon. "Please quit" and "interrupt" become typed messages on the app's loop port, with a reason string. The app's main loop handles them synchronously.
- **Avoid** asynchronous handlers, the silent drop when the 5-slot queue is full, and debugger consumption of the same queue the target reads. Give each observer its own subscription.

---

## 6. Readiness and multiplexing: the friction to avoid

Plan 9 has no `select` or `poll`. 9P reads block. Multiplexing is done with **one process (or kproc) per blocking source**, which feeds CSP channels that a thread `alt`s on.
- libdraw starts a proc to read `/dev/mouse` and another for the keyboard (`libdraw/mouse.c:43, 126`; `keyboard.c:20, 92`).
- Old-style libevent `rfork(RFPROC)`s a slave per source (`libdraw/event.c:308-320`).
- acme spends a proc on the plumber port (`acme.c:187-192, 350`).
- General blocking I/O goes through `ioproc()`: a dedicated proc runs the syscall and replies over a channel (`libthread/ioproc.c:32-100`, `iocall.c:7-30`).
- Cancellation means writing `interrupt` into the ioproc's `/proc/n/ctl` (`iocall.c:15-24`), or for servers, 9P `Tflush`. rio wires `flushc` into every blocking `alt` (`xfid.c:704-740`).

On the server side, rio uses one thread per outstanding request (`xfid.c:37`), and per-window state machines `alt` over about ten channels (`wind.c:1503+`).

The resulting friction:
- (a) stacks and procs per fd;
- (b) cross-proc channel hops on every input event;
- (c) cancellation through a note-like interrupt that races the syscall;
- (d) no way to wait on "fd readable OR timer OR child exit" in one call;
- (e) single-reader files, because fan-out is hard in this model (`xfid.c:297-305`).

**For Todhchai:** this confirms the architecture. Every handle is waitable on **one port**. The app loop waits once for input rings, configure events, plumb messages, timers, process exits and debug notifications. There are no helper threads, and cancellation is just closing or ignoring a wait. Concretely:
- The input ring signals the port. There is no `/dev/mouse` reader proc.
- Plumb and scripting channels deliver to the same port.
- Server-side, services use one port per thread with a fixed worker pool, not a thread per request.
- Every event stream (window state, visibility, intents) is multi-subscriber by design.
- Keep 9P's `Tflush` idea as **transaction cancel** in the IPC wire format (txid already exists), so a client can abandon a pending call without tearing down the channel.

---

## Summary of verdicts

| Plan 9 mechanism | Verdict |
|---|---|
| rio serves what it consumes, so it nests | **Adopt** as a compositor protocol requirement plus a test |
| Attach spec `new …` / `none` | **Adopt** as `connect(spec:)` and a control-only WM handle |
| wctl verbs | **Adapt**: typed, multi-subscriber |
| Resize through renaming plus `r` mouse message | **Avoid**: use `configure(configSeq)` plus buffer generations |
| devdraw screens and layers recursion, named images | **Adapt**: views host views, names become view-token handles |
| Kernel CPU rasterisation, Refbackup, global lock | **Avoid** |
| Plumber rules, ports, start/client, hold-for-client | **Adopt**, typed and MIME-aware, with handle payloads |
| acme `event` intercept with write-back default | **Adopt** as claim/decline intent streams in app scripting |
| /proc as remote-transparent debug, `hang`, Broken | **Adopt** through debugd channels plus a proxy |
| Notes (async string interrupts) | **Adapt** to port messages and exception channels |
| Proc-per-fd and ioproc multiplexing | **Avoid**: one port per loop |
