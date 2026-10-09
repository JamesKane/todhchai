# Todhchai Systems Research: BeFS, BeOS Lessons, Vulkan Compositor, Swift SDKs, Cyberpunk UI

Researched 2026-10-09. Markers: **[V]** means checked against a cited source in this session. **[K]** means background knowledge (well established but not re-checked this session). **[U]** means unverified or uncertain, so confirm it before you rely on it.

---

## A. BeFS: the original design, Haiku's experience, and a modern successor

### A.1 The original BFS (Giampaolo, *Practical File System Design*, 1999)

The primary source is the book. A free PDF is hosted on Giampaolo's site (nobius.org, see https://nobius.org/). [K: hosting location]

- **Lineage.** BFS replaced the database-backed OFS. Giampaolo and Cyril Meurillon started work in September 1996 and it shipped in May 1997. It was designed from the start as a 64-bit journaling file system. [V] https://en.wikipedia.org/wiki/Be_File_System
- **Allocation groups.** The volume is split into equal-sized allocation groups, similar in spirit to ext2 block groups or XFS AGs, to keep related data close together and spread out allocation. Free space is tracked by a bitmap. [K]
- **Extents (block runs).** A file's data is described by `block_run {allocation_group, start, len}` triples. The inode's data stream holds 12 direct runs, then indirect and double-indirect run blocks. Because the double-indirect layer uses fixed-size runs, the maximum file size is bounded in practice: roughly 260 GB at best and much less when fragmented. [V: size limit, Wikipedia] [K: structure]
- **Inodes.** One inode per filesystem block, addressed by its block_run. The inode holds the stat data, the data stream, and a **small-data area** that fills the rest of the block. [K]
- **Attributes.** Small attributes (name, type code, data) are packed into the inode's small-data area. Anything that does not fit goes into a hidden **attribute directory**, where each attribute is its own file-like inode. Reading a small attribute is therefore free once the inode is loaded. [K]
- **Directories** are B+trees keyed by name. [V] Wikipedia.
- **Indices.** Each volume has an index directory of B+trees. The defaults are `name`, `size`, and `last_modified`, and users can add an index on any attribute name with a fixed type (string, int32/64, float, double, time). Writing an indexed attribute updates its B+tree inside the same transaction. Attributes written before the index was created are *not* back-filled (`reindex` exists for that). [K]
- **Queries.** Queries are infix boolean expressions over indexed attributes, e.g. `((MAIL:status=="New")&&(BEOS:TYPE=="text/x-email"))`. At least one term must hit an index. The engine walks the most selective index and filters the remaining terms. [K: syntax; formula-mode existence V] https://www.haiku-os.org/files/programming_with_haiku/Programming_with_Haiku_Lesson_13.pdf
- **Live queries.** A query opened with `B_LIVE_QUERY` stays registered in the kernel. Every index update is checked against the open live queries, and `B_QUERY_UPDATE` messages (entry created or removed) go to a BMessenger target. That is how Tracker query windows and Deskbar mail counts update instantly. [K]
- **Journaling** covers metadata only, with a single fixed-size circular log. Transactions are batched. File data is not journaled. [K, plus the "single log" point is V via Haiku's issues page, cited below]
- **Node monitoring.** `watch_node()` and `watch_volume()` deliver BMessages for entry, stat, attribute and mount changes. This is separate from live queries, and the two complement each other. [K]

**UX examples worth copying [K unless marked]:**
- **People files** are zero-byte files of type `application/x-person` whose data lives entirely in `META:name`, `META:email`, `META:phone` and similar attributes. Tracker shows those attributes as columns, so a folder of People files acts like a spreadsheet you can sort and edit. A query such as `META:email=="*@be.com"` returns an address book.
- **Email as files.** Each message is one file, with headers and status held in BFS attributes so queries can search and filter them. [V] https://www.haiku-os.org/docs/userguide/en/workshop-email.html. Typical attributes are `MAIL:from`, `MAIL:subject`, and `MAIL:status`. A saved query such as "New mail" sits on the desktop and acts as a live inbox.
- **MP3s** with `Audio:Artist` and similar attributes give you a music library with no database. **Tracker's "by formula" Find mode** shows the raw query text. [V] Lesson 13 PDF above.

### A.2 Haiku's OpenBFS and its known limitations

- OpenBFS is a reimplementation by Axel Dörfler and others, started in 2002 and still Haiku's main file system. [V] Wikipedia.
- Haiku's own "FutureHaiku/BFSIssues" page states that some issues "can only be solved by breaking binary compatibility" and that it would be better "to start a new file system (based on the BFS sources)". The issues it lists: the index is not designed for user queries, so wildcard lookups are expensive; there is a single fixed-size log; metadata writes are effectively single-threaded; and space from files that were deleted while still open is lost on a crash until `checkfs` runs. [V via search snippet; the page itself blocked fetching] https://dev.haiku-os.org/wiki/FutureHaiku/BFSIssues
- Further limits: practical maximum file size of about 260 GB, no compression, no encryption, 1-second timestamps, and large headers. [V] Wikipedia. There are no checksums, no snapshots, and no CoW. [K]
- Index and query correctness has had real bugs. One ticket reports that `MAIL:to=*` returned only 202 of roughly 17,000 files until it was fixed. That shows how hard it is to keep indices consistent with attributes. [V via search snippet] https://dev.haiku-os.org/ticket/13254
- Queries are per-volume, and indices only exist where someone created them. Non-BFS volumes (FAT, network) have no queries. [K]

### A.3 What to borrow from modern file systems

| Source | Borrow | Notes |
|---|---|---|
| **APFS** (Giampaolo was lead engineer, project started in 2014) [V] https://en.wikipedia.org/wiki/Dominic_Giampaolo, https://bignerdranch.com/blog/wwdc-2016-a-quick-look-at-apfs | CoW B-tree metadata, an object map (OID to physical address) so nodes can move without rewriting parents, containers holding multiple volumes that share free space, O(1) file and directory clones, snapshots, per-file and per-volume encryption keys, nanosecond timestamps, atomic safe-save (rename-swap) | APFS left out **data checksums**, and that was widely criticized. [K] Do not repeat it. |
| **Spotlight** (Giampaolo started it) [V] https://nobius.org/ | Content indexing (text extraction via importer plugins), with the index kept *outside* the core FS and fed by a change journal (fseventsd) | Full-text search is too expensive to do synchronously inside FS transactions. |
| **ZFS** | End-to-end checksums stored in the parent block pointer (Merkle tree), self-healing with redundancy, transaction groups (TXG), ZIL for fast fsync, `send/recv` incremental replication | ZFS's TXG model is the cleanest crash-consistency story: an uberblock flip makes every commit atomic. [K] |
| **btrfs** | Generic CoW B-trees keyed by `(objectid, type, offset)` that hold every kind of metadata, reflinks, subvolumes, per-extent compression | Shows the cost: write amplification and fragmentation under random rewrites. [K] |
| **bcachefs** | B-tree nodes that are large and log-structured internally, so updates append inside a node; a btree-key-cache; erasure coding; tiering | Its project-health history is a warning. It went to "externally maintained" in 6.17 and was removed from mainline in 6.18. [V] https://lwn.net/Articles/1040120 |
| **NTFS USN journal** | A persistent, per-volume, monotonically numbered change log (`USN, file ref, reason flags`) that indexers and backup tools resume from after a reboot | This is what BFS lacked. Node monitoring is volatile, so indexers rescan after a crash. [K] |

### A.4 Proposed "modern BeFS" (working name *CroiFS* / *TFS*)

**Feature list**
1. CoW for all metadata. CoW for data by default, with an opt-out per file (nodatacow) for VM images and databases.
2. A checksum on every block (BLAKE3 or xxh3-128), stored in the parent pointer.
3. Atomic commits through a superblock/uberblock ring. A transaction group about every 1 to 5 s, plus an intent log for low-latency `fsync`.
4. Snapshots and writable clones per volume, file and directory clones (reflink), and incremental send/receive.
5. Containers with multiple volumes sharing a free-space pool, and per-volume quotas.
6. Inline compression per extent (zstd and lz4) with a heuristic to skip incompressible data.
7. Encryption per volume and per file key class, using AES-XTS or Adiantum. Metadata is encrypted too, except the index structure itself (see tradeoffs).
8. **First-class typed attributes**: inline small-data area, overflow into an attribute B-tree, and *all attributes stored as keys in the main FS tree* (btrfs-style) rather than in hidden directories.
9. **Declarative indices** (attribute name, type, collation), with automatic back-fill and a reindex done as a background job.
10. **Query language v2**: keep BFS infix syntax for compatibility and add typed literals, ranges, `IN`, case-folding and Unicode-normalized collation, prefix and trigram indices for wildcards, and ordering and limits.
11. **Live queries** as before, plus resumable cursors.
12. **Persistent change journal** (a USN equivalent) as the backbone of node monitoring, live-query catch-up, the content indexer, backup and sync.
13. **Content index outside the FS**: a user-space indexer service (Spotlight-style importer plugins, Translation-Kit-style) that consumes the change journal and stores a full-text and vector index in its own volume or file. The FS only stores structured attributes.
14. NVMe awareness: 4 KiB minimum block size with 16 to 64 KiB B-tree nodes, multi-queue submission, discard/TRIM batching, alignment to zoned-namespace and FDP placement hints (optional), and per-CPU allocation groups so allocation needs no global lock.
15. 64-bit everything, nanosecond times, 2^64 inodes, extents of up to 2^32 blocks each, and no fixed-depth indirect limit.

**On-disk sketch**
```
[Container superblock ring (N copies, checksummed, highest valid TXG wins)]
  -> Object map B-tree        (OID -> {paddr, csum, txg})   // APFS-style indirection
  -> Space manager            (per-AG free-extent B-trees + per-CPU reservations)
  -> Volume table             (vol_id -> root OIDs, keybag ref, snapshot list)
Volume:
  FS tree (CoW B+tree, key = (inode_id, kind, sub_key)):
     kind=INODE    -> stat, flags, small-data inline attrs (<~200B)
     kind=DIRENT   -> (parent, hash(name)) -> child inode, type
     kind=XATTR    -> (inode, attr_name) -> type, value | extent ref
     kind=EXTENT   -> (inode, file_off) -> paddr, len, csum[], compression
  Extent-ref tree (refcounts for clones/snapshots)
  Index forest:   one B+tree per declared index, key = (value, inode_id)
  Change journal: append-only log of (seq, txg, inode, parent, reason, attr_name)
  Snapshot tree:  snap_id -> FS-tree root + journal seq
```

**Hard tradeoffs (the point of this section)**
- **Live queries vs CoW batching.** BFS evaluated live queries synchronously inside each index update. With TXG batching, an attribute write is not durable for up to N seconds. Options: (a) notify on the *in-memory* commit and accept that a crash can "un-happen" a notification, or (b) notify only after the TXG syncs and accept added latency. Recommendation: send in-memory notifications carrying the journal sequence number, so consumers resync from the persistent change journal after a crash. [design judgment]
- **Index update cost.** Each indexed attribute write costs one extra CoW B-tree path rewrite, i.e. O(depth) node copies per index per TXG. Batching per TXG amortizes this. Without it, write amplification compounds (CoW of the FS tree plus every index tree). Cap the default index set and make users opt in.
- **Snapshots and indices.** Should indices see snapshots? Cheapest: indices cover only the live head, and querying a snapshot does a full scan. Snapshot-aware indices (keyed with a txg range) are possible but double the complexity.
- **Encryption and indices.** An index on `META:email` leaks plaintext ordering. Either encrypt index keys deterministically per volume (leaks equality and order) or keep indexed volumes unencrypted. APFS-style per-file classes make this worse, because an index sitting outside the per-file key cannot be encrypted with it.
- **Wildcard queries.** BFS's B+trees only accelerate prefix matches. `*foo*` needs trigram indices, and those are expensive to maintain inside the FS. That is a strong argument for pushing them to the user-space indexer.
- **Inline attributes vs checksummed CoW nodes.** A fat inode block (BFS-style) is rewritten on every attribute change. Storing attributes as separate B-tree keys bounds the rewrite cost.
- **Scope.** A checksummed CoW FS with snapshots is several person-years of work (APFS, ZFS, and bcachefs all took more than 5 years). Staged plan: v0 is a BFS-compatible (or ext2-simple) FS with attributes and indices but no CoW, so the query UX is usable early. v1 adds CoW and checksums. v2 adds snapshots, compression, and encryption.

---

## B. BeOS desktop and system architecture lessons

### What BeOS did [K unless marked]
- **Pervasive multithreading.** Each `BWindow` is a `BLooper` with its own thread, the `BApplication` has a thread, and the app_server keeps a matching server-side thread per window. This made the UI responsive on 1990s SMP machines but forced every app to deal with locking (`LockLooper`) and cross-window deadlocks.
- **app_server** was a user-space display server that did server-side drawing (a BView command stream) and owned windows, fonts and input. Haiku's app_server keeps this design. https://www.haiku-os.org/docs/develop/servers/app_server/ [U: exact doc path]
- **Tracker** (the file manager and desktop) was built on attributes, queries and node monitoring. **Deskbar** was the task bar and tray, and its tray icons were often **replicants**: archived `BView`s (`BArchivable` turned into a BMessage) that could be dropped into another app and live there, with their code loaded from the source app's add-on.
- **Translation Kit** used system-wide translator add-ons that converted formats into canonical intermediates (B_TRANSLATOR_BITMAP and others). Every app gained new image formats the moment a translator was installed. This is the precedent for Spotlight importers.
- **Media Kit** was a graph of `BMediaNode`s (producers, consumers, filters) in possibly different processes, with a shared time source. Each node published its *latency*, and the roster computed downstream latency so buffers were timestamped to arrive "just in time". Real-time threads were used, plus shared-memory buffer groups.
- **BMessage scripting** (`hey` on Haiku) let any app expose properties (`GET Title OF Window 0`) through specifiers, an AppleScript-like system for free that came from the messaging architecture.
- **The pitch**: "the media OS". Low-latency audio and video with many streams on cheap SMP hardware, and a fast boot.

### What aged well
- Typed attributes plus queries as a user-visible data model. Spotlight, Windows Search, and GNOME Tracker all reinvented parts of it, and none made it as first-class.
- Message-passing app model, add-on registries (translators, media nodes, input and screen-saver add-ons), and a consistent MIME type registry (`BEOS:TYPE`).
- Explicit latency accounting in the media graph. PipeWire's design is the modern descendant in spirit. [K]
- Single-vendor coherence: one API, one look, and a fast desktop.

### What failed or aged badly
- **Thread-per-window** gave every app a multithreaded UI whether it needed one or not. Lock-ordering deadlocks between windows and data races in app code were endemic. The modern consensus is one UI thread (or one per "scene") plus worker pools and message passing. [K]
- **C++ ABI fragility.** BeOS shipped C++ classes as its ABI. Adding a virtual method or field broke subclasses, so Be padded classes with `_ReservedFoo1()` virtuals and reserved data. Haiku is still bound to the gcc2 ABI on 32-bit x86 for BeOS binary compatibility, through a hybrid gcc2/modern build. [K] https://www.haiku-os.org/guides/building/gcc-hybrid [U: exact URL]
- Replicants were a security and stability hole: foreign code running in-process in Tracker or Deskbar.
- No security model to speak of (single user, everything root), and no memory protection between Media Kit nodes running in one process.
- Drivers. BeOS died partly because hardware support could not keep up. This is directly relevant to section C.

### Haiku's lessons [K]
- It took more than 20 years to reach a modern-ish beta, mostly because binary compatibility was kept as a hard constraint.
- Porting software through POSIX compatibility layers and Qt/GTK ports brought apps but diluted the native UX.
- Drivers: Haiku ported FreeBSD network drivers through a compatibility layer, and ported Linux DRM (radeon/intel) much later. Borrowing driver ecosystems is the only scalable approach for a small OS.

### Recommendations for Todhchai
- Keep: attributes plus queries, translators (as sandboxed out-of-process services), a media graph with latency accounting, message scripting (expose it as a typed IPC schema), and a MIME and type registry.
- Change: structured concurrency (one main actor per app plus executors) instead of thread-per-window. Make the system ABI a **C ABI or IDL-defined IPC protocols**, never Swift or C++ class layouts. Run replicants as out-of-process embedded surfaces (Flatland-style view embedding) rather than in-process code.

---

## C. Vulkan compositor and desktop

### How modern compositors are built
- **KWin and Mutter** are mostly GL-based (KWin has been working on Vulkan [U]). Both now support direct scanout of fullscreen client buffers, hardware planes (cursor and overlay), VRR, HDR and color management, and `wp_tearing_control`. [K]
- **wlroots and Sway**: wlroots has a Vulkan renderer and a scene graph. wlroots 0.20 (March 2026) completed color-management-v1 across the Vulkan renderer, backend and scene graph, and Sway 1.12 supports HDR10 with the Vulkan renderer. [V] https://www.phoronix.com/news/wlroots-0.20-Sway-1.12-rc1, https://linuxiac.com/sway-1-12-wayland-compositor-released-with-hdr10-and-window-capture/
- **gamescope** (Valve's micro-compositor): uses DRM/KMS to flip game frames directly to the screen, "even when stretching or when notifications are up". When the GPU is needed for compositing, it uses **async Vulkan compute**, so the frame shows up quickly even while the game keeps the graphics queue busy. Simple color transforms belong in display-engine LUTs and CTMs at scanout, not in shaders. [V] https://github.com/ValveSoftware/gamescope. It also provides FSR/NIS upscaling, integer scaling, HDR (including inverse tone mapping), VRR, and frame limiting. [K, plus FSR wiring U]
- **Wayland presentation protocols**: `tearing-control-v1` (the client hints async flips), `fifo-v1` and `commit-timing-v1` (target presentation times, added in wayland-protocols 1.38, with Mesa using them for true FIFO). [V] https://wayland.app/protocols/tearing-control-v1, https://wayland.app/protocols/commit-timing-v1, https://www.phoronix.com/news/Wayland-Protocols-1.38. `wp_presentation` gives exact presentation feedback timestamps. [K]
- **Fuchsia Scenic/Flatland**: a retained-mode 2D compositor for rectangular layers only. Clients enqueue commands and `Present()`. Sessions embed one another through view tokens. Scenic either sends layers directly to the display controller or composites them with Vulkan. [V] https://fuchsia.dev/docs/concepts/ui/scenic/flatland, RFC-0162 https://fuchsia.googlesource.com/fuchsia/+/HEAD/docs/contribute/governance/rfcs/0162_flatland.md. For a Zircon-style kernel, this is the closest model to copy.
- **Apple WindowServer and Core Animation**: apps build a layer tree. The render server (out of process) animates and composites it, so animations run without the app's main thread. Transactions are committed atomically. [K]
- **Windows DWM**: flip-model swapchains. *Independent Flip* scans the app's buffer out directly "with the same efficiency as fullscreen exclusive". MPO (multiplane overlay) keeps Independent Flip working when other content overlaps, and Independent Flip "can get down to 1 frame of latency". [V] https://devblogs.microsoft.com/directx/dxgi-flip-model/, https://learn.microsoft.com/en-us/windows-hardware/drivers/display/multiplane-overlay-support

### Recommended architecture: "Lumen" compositor (name illustrative)
1. **Flatland-style protocol**: a retained 2D layer tree per client (rects, images, solid colors, clip, opacity, transforms limited to 2D affine), atomic `present(targetTime)` with release fences, and view-token embedding for replicants and widgets.
2. **Plane-first scheduling.** Each frame, try in order: (a) **direct scanout** of a fullscreen game buffer on the primary plane; (b) game on the primary plane with overlays (cursor, HUD, notifications) on hardware planes; (c) composite. Only (c) costs GPU time. This is the DWM Independent Flip and MPO idea, and gamescope's approach.
3. **Game mode.** When a game is focused and fullscreen, bypass all effects. Honor the tearing hint with an async page flip, use VRR (the display follows the game's present rate), and apply LFC below the VRR floor. Do color transforms through KMS-style degamma, CTM and gamma LUT properties in the display engine.
4. **Present timing feedback.** Expose `wp_presentation`-equivalent feedback (actual scanout time, refresh period, VRR state) plus a predicted latch deadline, so engines can do frame pacing (Vulkan `VK_KHR_present_wait` and `VK_GOOGLE_display_timing` / `VK_EXT_present_timing`, the last one [U] on status).
5. **Late latching.** Composite as close to vblank as possible: measure composite cost, then start at `vblank - cost - margin` (as Mutter and KWin do). Put composition on an **async compute queue** with high queue priority (`VK_EXT_global_priority`) so it can preempt or overlap with the game.
6. **Effects without latency cost.**
   - Effects (bloom, glow, CRT and scanline, chromatic aberration) run **only on desktop surfaces and window chrome**, never on a direct-scanout game buffer.
   - Cache static blurs and glows: recompute only when damaged, keep a damage-tracked layer cache, and render bloom at 1/4 resolution with a dual-Kawase or downsample/upsample pyramid.
   - CRT and scanline effects are a *final optional pass* the user can toggle, and they are disabled automatically when a game is in direct scanout or the frame budget is tight.
   - Prefer effects in fragment shaders driven by SDF chrome (see E), which cost almost nothing compared with full-screen post passes.
7. **HDR and color.** Composite in linear FP16 scRGB or PQ. Store theme colors in a wide gamut so neon glows can use HDR headroom. This is a natural cyberpunk win.

### GPU drivers: the biggest risk
- **Fuchsia Magma model**: the Vulkan ICD runs as a library inside each app with no hardware access. It talks over IPC (Zircon channels) to a Magma System Driver that owns the GPU. Each connection gets isolated memory, and a driver fault kills only that connection ("device lost"). ICDs must be statically linked against everything except libc and the zircon library. [V] https://fuchsia.dev/fuchsia-src/concepts/graphics/magma/design. Mesa already contains Magma support for some drivers (Intel ANV and Mali). [K/U] This maps directly onto croi.
- **Venus**: Mesa's Vulkan-over-virtio-gpu protocol, with virglrenderer on the host. QEMU gained VirtIO-GPU Vulkan (Venus) support around 9.2. Venus exposes Vulkan 1.4, ray tracing (2025) and mesh shaders (Mesa 26.0). [V] https://docs.mesa3d.org/drivers/venus.html, https://www.phoronix.com/news/Venus-Vulkan-Mesh-Shader
- **virtio-gpu native context**: guests run the *real* RADV/radeonsi over a virtio transport, merged for AMD in Mesa 25.0, with Intel in progress. Faster than Venus. [V] https://phoronix.com/news/AMDGPU-VirtIO-Native-Mesa-25.0
- **Native Mesa drivers**: RADV (AMD), ANV (Intel), NVK (NVIDIA, Vulkan 1.4 conformant including Blackwell; performance still behind proprietary in 2026). [V] https://www.phoronix.com/news/Vulkan-1.4-NVK-Blackwell, https://phoronix.com/news/NVK-Mesa-26.2-Performance. Turnip (Adreno) and PanVK (Mali) cover ARM. [K] All of them assume a Linux DRM kernel driver (amdgpu, i915/xe, nouveau with GSP firmware). Porting the *kernel* half is the hard part.
- **lavapipe** is a CPU Vulkan driver in Mesa: zero hardware dependencies and slow, but conformant. [K]

**Staged path**
1. **Stage 0:** a framebuffer (UEFI GOP) plus a software compositor. Port **lavapipe** (needs LLVM, threads and a libc) so the compositor and SDK speak Vulkan from day one.
2. **Stage 1:** a **virtio-gpu** driver in croi (2D first, then 3D), plus **Venus** in user space against QEMU with `-device virtio-gpu-gl,venus=on` (or `virtio-vga-gl`). This gives hardware-accelerated Vulkan in a VM with no real GPU driver work. Shape the kernel driver and IPC interface after Magma (ICD in process, MSD as a userspace driver process).
3. **Stage 2:** virtio-gpu **native context** for AMD in QEMU. This exercises the real RADV user-mode driver against a thin transport and is a stepping stone to bare metal.
4. **Stage 3:** bare-metal **AMD** (best-documented open hardware). Write an MSD that reimplements the needed amdgpu kernel functions (ring submission, VM/GTT, firmware loading, display through DC) in a user-space driver process, with RADV as the ICD. Alternatively build a "linuxkpi"-style shim (as FreeBSD's drm-kmod does) to host Linux amdgpu code. [K] Expect years of work. Display (KMS/DC) alone is huge.
5. Intel (xe) second, NVIDIA (nova/nouveau and GSP) last.

---

## D. Swift for systems and SDKs (as of October 2026)

### Embedded Swift status
- **Swift 6.2-era status table** [V] https://raw.githubusercontent.com/swiftlang/swift/release/6.2/docs/EmbeddedSwift/EmbeddedSwiftStatus.md (the docs have since moved to https://docs.swift.org/embedded/documentation/embedded):
  - Unsupported long-term: library evolution, ObjC interop, non-WMO builds, `Mirror`/reflection, non-final generic class methods.
  - Not supported in 6.2: `Codable`, weak and unowned references, parameter packs, lazy collections, float and integer parsing, `VarArgs`. KeyPaths are partial. Concurrency is "partial, experimental (single-threaded basics)". Synchronization offers `Atomic` only, no `Mutex`. C and C++ interop are supported.
- **Swift 6.4 (blog dated 2026-08-20; 6.4 is not yet released as of this writing [U on final release date])** adds **all existentials, including `Any`** (generic functions still cannot be called on `any` values), **untyped `throws`** (which heap-allocates, so prefer typed throws), **full metatype support**, **throwing tasks and task groups** in the embedded concurrency library, and float parsing. [V] https://swift.org/blog/embedded-swift-improvements-coming-in-swift-6.4/
- Practical impact for croi: kernel code should use generics, typed throws, `~Copyable` handles, no existentials on hot paths, and no allocation in IRQ paths. Embedded concurrency is still not a multi-threaded SMP executor, so **do not build kernel scheduling on Swift concurrency**. Use it in userland. [design judgment; multi-thread embedded concurrency status U]

### Ownership and low-level features
- `~Copyable` (SE-0390, 0427), `borrowing`/`consuming` (SE-0377), `~Escapable` (SE-0446), `Span`/`MutableSpan`/`RawSpan` (SE-0447, 0456 and later), `InlineArray` (SE-0453) shipped around 6.2, along with typed throws (SE-0413, 6.0). [V partial] https://mjtsai.com/blog/2025/03/19/lifetime-dependencies-in-swift-6-2-and-beyond. `@lifetime` annotations were still experimental or underscored in 6.2 [V], and their state in 6.3 and 6.4 is [U].
- These map well onto kernel and driver objects: capability handles as `~Copyable` (moving one transfers ownership, Zircon-style), DMA buffers as `Span`, and fixed-size arrays in structs through `InlineArray`.

### Interop and C ABI
- **SE-0495 `@c`** (accepted October 2025) formalizes `@_cdecl` for C-compatible functions *and enums*, with C-compatibility type checking. [V] https://forums.swift.org/t/accepted-se-0495-c-compatible-functions-and-enums/82833. It is the foundation of a C ABI story.
- C++ interop is mature enough for C++ libraries, and it works in Embedded mode. [V, status table above]
- **Vulkan in Swift**: importing `vulkan.h` directly works through a module map. Wrappers include **henrybetts/swift-vulkan** (generated from `vk.xml`, Swift-style names, `throws`, Vulkan 1.2) and ctreffs/SwiftVulkan (a system-library package that builds on Swift 6.3 for Linux). [V] https://github.com/henrybetts/swift-vulkan, https://swiftpackageindex.com/builds/4F04BD14-89FF-4C06-B641-B7E589FEEABB. Recommendation: generate your own bindings from `vk.xml` with a Swift script, emitting `~Copyable` handle wrappers and typed-throws results, plus a thin `@inline(__always)` layer so hot paths stay zero-cost.

### Macros
Swift macros (SE-0382, 0389) are good for codegen such as IPC stubs, ECS component registration, and shader reflection. SwiftGodot uses `@Godot`, `@Export`, `@Callable`, and `@Signal` macros. [V] https://swiftpackageregistry.com/migueldeicaza/SwiftGodot. Cost: macros run as separate host plugin processes that depend on swift-syntax, which hurts build times (prebuilt swift-syntax has eased this [U]). On a new OS, macro *plugins run on the host*, so cross-compiling is fine.

### Concurrency for games and audio
- SE-0392 (custom actor executors) and SE-0417 (task executor preference) let you pin actors and tasks to your own threads or executors. [V] https://forums.swift.org/t/accepted-se-0417-task-executor-preference/69705
- **Games**: use a job system (a fixed worker pool with lock-free deques) as a custom `TaskExecutor`. Keep the frame loop synchronous and use `async` for loading and streaming. Swift's default global pool has no frame-deadline awareness. [design judgment]
- **Real-time audio**: no async, no actor hops, no allocation, no locks, and no ARC traffic (retain and release are atomic, and a release can deallocate) on the audio thread. Write the DSP callback with `~Copyable` and `Span` over preallocated buffers and lock-free SPSC rings. Concurrency is for the control plane only. [K, consistent with Apple guidance]
- ARC in hot loops is the main performance trap. `~Copyable`, `borrowing`, and `-Ounchecked` per module help, and so does profiling `swift_retain`.

### Swift off Apple platforms
- Linux and Windows are officially supported toolchains [K]. The Android SDK preview (nightly) was announced on 2025-10-24 by the Android Workgroup, formed June 2025. [V] https://www.heise.de/en/news/Apple-Meets-Android-Swift-Programming-Language-Gets-an-Android-SDK-10901579.html. WASM SDKs exist [K]. Embedded and freestanding targets cover ARM, RISC-V and x86 [K]. Porting full Swift to Todhchai needs: an LLVM target triple (`x86_64-unknown-todhchai`), a libc (port a small one such as musl or picolibc, or write your own), Foundation (swift-foundation is now pure Swift and more portable [K]), and Dispatch (or skip it and provide a native concurrency executor).
- **Compile time**: whole-module optimization is required for Embedded, type-checker blowups happen on complex literal expressions, and generics are specialized everywhere. Keep modules small, avoid deep generic or SwiftUI-style result-builder nesting in engine code, and use explicit types.

### Existing game and graphics work
- **SwiftGodot** (Miguel de Icaza): GDExtension bindings plus SwiftGodotKit for embedding Godot, tracking Godot 4.x. [V] above
- **Swift on Playdate**: Apple's swift-playdate-examples (Embedded Swift on a Cortex-M7) and PlaydateKit. [V] https://swift.org/blog/byte-sized-swift-tiny-games-playdate/, https://github.com/finnvoor/PlaydateKit
- Other projects: Fireblade ECS, and Swift bindings to SDL3 and raylib (several community packages). [K/U]

### Recommended SDK layering
```
L0  croi syscalls + IPC wire format (IDL; versioned; language-neutral)
L1  libtodhchai.so  : stable C ABI (handles as u32/u64, POD structs, explicit size/version fields,
                       no exceptions, caller-allocated buffers). Generated C header.
                       Implemented in Swift via @c functions + ~Copyable internals.
L2  Swift overlay    : idiomatic Swift (~Copyable handles, typed throws, async where non-RT)
L3  Kits             : AppKit-ish "Interface Kit", Media Kit, Storage Kit (attrs/queries),
                       Game Kit (window/input/audio/timing, "SDL-shaped"), Vulkan direct access
```
- **Every system service is reachable from the C ABI.** Generate headers for C/Zig (`@cImport`), Odin (`foreign import`), Rust (`bindgen`, or ship a `-sys` crate) and Jai from a single IDL. The Handmade crowd wants: a raw window plus input plus audio-buffer plus timer API, raw Vulkan, no mandatory framework, no mandatory runtime initialization, and static linking as an option.
- Do not expose Swift types across process or library boundaries. Swift's ABI is stable only on Apple platforms with library evolution, and Embedded explicitly lacks library evolution. [V, status table]
- Version structs with a `size` field (Win32/Vulkan `sType`/`pNext` style) so ABI growth never breaks callers. This fixes the BeOS fragile-base-class problem from section B.

---

## E. Retro-future cyberpunk UI (short)

**References**: Blade Runner (1982) and 2049 (amber and teal monochrome CRTs, the Esper machine) [K]; Ghost in the Shell (1995) (green wireframe data-dives, dense kanji/hex readouts); Alien's Nostromo terminals (MU-TH-UR green phosphor, chunky block type); **eDEX-UI** (the Tron/sci-fi terminal desktop, now archived) https://github.com/GitSquared/edex-ui [K: archived status]; Cyberpunk 2077 UI (red/cyan on near-black, glitch and chromatic shifts, angled corners); Tron: Legacy; Deus Ex: Human Revolution (black-gold); the BeOS **yellow tab** title bars, an excellent signature element to keep as a neon tab.

**Rendering cheaply on the GPU**
- **SDF/MSDF text** (msdfgen atlases) supports crisp scaling, outlines, and glow from a single texture lookup: glow = `smoothstep` on distance beyond the edge. [K]
- **Analytic SDF shapes** for chrome: rounded or chamfered rects, angled cut corners, and borders in a single fragment shader per quad. No textures needed, and resolution independent.
- **Glow and bloom**: compute it from the SDF for UI elements (nearly free). Use a real bloom pass (downsampled dual-Kawase) only for the HDR desktop layer, and cache it on damage.
- **CRT, scanline, and phosphor** as an *optional* final pass: scanlines from `sin(y·π)`, a shadow-mask or aperture-grille pattern, barrel distortion, vignette, a temporal phosphor-decay buffer, and slight chromatic offset. Disabled under direct scanout or game mode.
- **Palettes**: themes as small token tables (bg near-black `#0a0a12`, neon cyan, magenta, amber, and a "Be yellow" accent) defined in HDR nits for glow headroom. Provide an accessibility variant with no flicker, no chromatic aberration, and high contrast.
- **Glitch effects**: driven by events (notifications, errors), short-lived, and never constant, which protects readability and motion sensitivity.

---

## Key sources
- BFS: https://en.wikipedia.org/wiki/Be_File_System · https://dev.haiku-os.org/wiki/FutureHaiku/BFSIssues · https://dev.haiku-os.org/ticket/13254 · https://www.haiku-os.org/files/programming_with_haiku/Programming_with_Haiku_Lesson_13.pdf · https://nobius.org/ · https://en.wikipedia.org/wiki/Dominic_Giampaolo · https://lwn.net/Articles/1040120
- Compositors: https://github.com/ValveSoftware/gamescope · https://fuchsia.dev/docs/concepts/ui/scenic/flatland · https://devblogs.microsoft.com/directx/dxgi-flip-model/ · https://wayland.app/protocols/tearing-control-v1 · https://wayland.app/protocols/commit-timing-v1 · https://www.phoronix.com/news/wlroots-0.20-Sway-1.12-rc1
- Drivers: https://fuchsia.dev/fuchsia-src/concepts/graphics/magma/design · https://docs.mesa3d.org/drivers/venus.html · https://phoronix.com/news/AMDGPU-VirtIO-Native-Mesa-25.0 · https://www.phoronix.com/news/Vulkan-1.4-NVK-Blackwell
- Swift: https://swift.org/blog/embedded-swift-improvements-coming-in-swift-6.4/ · https://forums.swift.org/t/accepted-se-0495-c-compatible-functions-and-enums/82833 · https://forums.swift.org/t/accepted-se-0417-task-executor-preference/69705 · https://github.com/henrybetts/swift-vulkan · https://swift.org/blog/byte-sized-swift-tiny-games-playdate/
