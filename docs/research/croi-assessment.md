# croi assessment for Todhchai planning

Date: 2026-10-09. Sources: `/home/jkane/Projects/OS/croi` at `a6a1a64` (5 commits, all 2026-10-09), `/home/jkane/Projects/OS/fuchsia` checkout, Swift 6.4.0 toolchain at `~/.local/share/swiftly/toolchains/6.4.0`.

An important point about the reference tree: the Zircon checkout is partway through a migration to Rust. Most of `zircon/kernel/object/*_dispatcher.cc` files are now thin C++ shells over `*_dispatcher.rs` plus `*_ffi.rs` (for example `object/channel_dispatcher.cc` only forwards to `rust_channel_dispatcher_state_*`). The kernel tree has about 126K lines of Rust. For croi, the Rust versions are often the better reference because their ownership model maps closely onto `~Copyable` Swift. The LOC figures below count C++ and Rust together and leave out tests.

---

## 1. Current state of croi

**Size:** about 1,730 lines of Swift plus about 830 lines of assembly and C. It boots to a halt on all three arches.

**What exists:**

| Area | Files | Status |
|---|---|---|
| UEFI loader | `boot/Loader/*.swift` (Main, KernelFile, KernelElf, Acpi, MemoryMap, BootPageTables, Firmware, Console, Physical), `boot/entry.c`, `boot/arch/*/enter.S` | Works. Reads `\croi\kernel.elf`, relocates it, finds the RSDP and SPCR, builds boot page tables, calls ExitBootServices, then jumps. On arm64 it drops from EL2 to EL1 (`boot/arch/arm64/enter.S`, 191 lines). The ELF is converted to PE32+ by `tools/elf2efi.py`. |
| Handoff ABI | `lib/handoff/include/handoff.h` | v1, 96 bytes: memory map, RSDP, EFI system table, UART. **It has no ramdisk/bootfs, framebuffer (GOP), cmdline or SMBIOS fields.** |
| Kernel address space | `kernel/Kernel/KernelPageTables.swift`, `KernelLayout.swift`, `lib/pagetables/PageTables/*.swift` | Physmap at `0xffff8000_00000000` (rv64: `0xffffffc0_00000000`, Sv39), W^X image at `0xffffffff80000000`, empty low half. The builder is generic over `PageTableMemory`. It can only map: there is no unmap, no protect, and no ASID/PCID. |
| Early allocator | `kernel/Kernel/BootAllocator.swift` | Bump allocator that never frees. **There is no PMM and no heap.** |
| Exceptions | `kernel/Kernel/Exceptions.swift`, `kernel/arch/*/exceptions.S` | Vectors are installed: amd64 IDT/TSS/IST1, arm64 VBAR_EL1, rv64 stvec. Breakpoints round-trip. Every other exception dumps registers and panics. **Only kernel-mode traps are handled. There is no user-mode entry or return path, no syscall entry, and no IRQ handling.** |
| Console and panic | `Uart.swift` (polled 16550 PIO/MMIO and PL011), `Panic.swift`, `lib/fmt/Fmt/TextOutput.swift` | Allocation-free formatting through the `TextOutput` protocol over `Span<UInt8>`. |
| Runtime | `lib/rt/string.c` (byte-loop mem*), `stack_protector.c` | Minimal. |
| Build | `CMakeLists.txt`, `CMakePresets.json`, `cmake/toolchain.cmake`, `cmake/arch/*.cmake`, `ld/image.ld`, `tools/qemu.sh` | One tree per arch. A QEMU smoke test checks for `croi kernel: halting`, plus an arm64 EL2+GICv3 variant. |

**Not present (all stubs or absent):** interrupt controllers (APIC/IOAPIC, GIC, PLIC/AIA), timers, ACPI table parsing beyond SPCR, SMP, PMM, VMM, heap, threads, scheduler, syscalls, user mode, handles, kernel objects, IOMMU and PCI. Stack guard pages are missing, and so is KASLR. The CLAUDE.md file also says amd64 has no 5-level paging.

**Toolchain and flags** (`cmake/toolchain.cmake`):
- Swift 6.4.0 (`.swift-version`), found through swiftly. Uses the bundled clang and lld.
- Triples: `x86_64-unknown-none-elf`, `aarch64-none-none-elf`, `riscv64-none-none-eabi` (rv64imac, lp64 soft-float, medany).
- Swift flags: `-enable-experimental-feature Embedded -enable-experimental-feature Lifetimes -parse-as-library -strict-memory-safety -Werror StrictMemorySafety -Werror EmbeddedRestrictions -Wwarning PerformanceHints -enforce-exclusivity=unchecked -Xfrontend -function-sections`, whole-module, `-Osize`.
- C: `-std=c23 -ffreestanding`, PIE, `-fstack-protector-strong`, frame pointers kept. Static PIE link with `--gc-sections --orphan-handling=error`.
- No FP or SIMD in the kernel. amd64 Swift builds with `-mno-sse -mno-mmx`, which means `Double` would silently compile to x87.

**Conventions Todhchai userspace should inherit** (from `croi/CLAUDE.md`):
1. Build with `-strict-memory-safety` as an error. Every unsafe use is marked `unsafe`. Types that wrap raw pointers are `@safe` and have `@unsafe` initializers that state their contract (see `Uart`).
2. Use ownership-era APIs: `Span`, `MutableSpan`, `RawSpan`, `InlineArray`, `~Copyable`, `UniqueBox`/`UniqueArray`, `Atomic`, `@section`/`@used`, and `@_lifetime` on span-returning properties.
3. Use typed throws everywhere (`throws(MapError)`). Keep existentials and untyped `throws` out of hot paths, and leave `PerformanceHints` on as warnings.
4. At the C boundary, declare in a C header and implement in Swift with `@c @implementation`. Import C constants as typed C23 enums.
5. Write generic library code as `@inlinable` so that embedded clients can specialize it. `Fmt` and `PageTables` already do this.
6. Every C or assembly file must justify itself in its header comment.
7. Check the link for hidden allocations (`ld.lld --why-live=swift_slowAlloc`). In userspace this becomes "no allocation on RT threads".

---

## 2. What croi needs before userspace exists (dependency order)

Approximate Zircon LOC per area (C++ and Rust, tests excluded): `object/` 45.8K, `vm/` 65.5K, `kernel/` 19.4K, `lib/syscalls` 9.9K, `lib/userabi` 3.6K, `dev/iommu` 9.6K, arch/x86 29K, arch/arm64 18.6K, arch/riscv64 12.8K.

| # | Component | Zircon reference and size | Todhchai relevance |
|---|---|---|---|
| 0 | **Platform basics:** ACPI parsing (MADT, HPET, MCFG, DMAR/IVRS/IORT, RHCT), interrupt controllers, per-CPU timer, monotonic clock (TSC/CNTVCT/time CSR) | `platform/` 8.6K, `dev/interrupt` 3K, `dev/` 18K | The tick and clock source decide frame-pacing accuracy. You need a tickless one-shot timer from the start. |
| 1 | **PMM** with page structs, arenas, free lists, and reclaim of HANDOFF and ACPI_RECLAIM memory | `vm/pmm*.{cc,rs}`, `pmm_node.rs` 4.3K, `pmm_arena.rs` 0.7K, `page.rs` 1K | Contiguous allocation is required for GPU/display scanout buffers without an IOMMU. |
| 2 | **Kernel heap and slab** (ownership-safe `UniqueBox` backing) | `vm/page_slab_allocator.rs` 0.9K, plus `lib/heap` | Every kernel object depends on it. |
| 3 | **Threads, context switch, wait queues, timers, mutexes** | `kernel/thread.cc` 2.5K, `wait.cc` 0.75K, `timer.cc` 0.7K, `mutex.cc` 0.7K, `owned_wait_queue.cc` 2.2K | You need **priority inheritance** (OwnedWaitQueue) from the first version. The audio and compositor paths depend on it. |
| 4 | **Scheduler:** Zircon's unified fair (WFQ-like) plus EDF deadline with capacity, period and relative deadline | `kernel/scheduler.cc` 3.9K, `scheduler_pi.cc` 0.7K, `cpu_search_set.cc`. Profiles via `ZX_PROFILE_INFO_FLAG_DEADLINE` (`zircon/system/public/zircon/syscalls/profile.h:21`) | **The most important item for Todhchai.** Audio mixer, compositor and input threads run as deadline threads. Port the design, not the 3.9K lines. |
| 5 | **SMP:** AP bring-up (the BootAllocator already reserves the first 1 MiB for the amd64 trampoline), IPIs, TLB shootdown, per-CPU data | `kernel/mp.cc` 0.6K, `percpu`, arch code | Games need many cores. Pinning and affinity (CPU masks in profiles) matter. |
| 6 | **VMM:** address spaces, VMAR tree, mappings, page fault handler, VMOs (paged, physical, contiguous), COW clones, cache policy | `vm_cow_pages.cc` alone is 8.2K, `vm_page_list` 5.9K, `vm_mapping` 1.9K, `vm_address_region` 1.7K, `vm_object_paged` 2.3K. Total ~65K including eviction and compression | **The biggest single piece.** Phase it: (a) eager, non-COW anonymous and physical VMOs with VMARs, (b) COW clones for ELF loading, (c) pager, eviction, compression later. Zero-copy buffer sharing between GPU, display, compositor and clients is VMO sharing plus `zx_vmo_set_cache_policy` (WC/uncached). |
| 7 | **Handles and rights:** handle table, koids, rights masks, duplicate/replace | `object/handle*.{cc,rs}` ~1.8K, `user_handles.rs` 0.5K | A natural fit for `~Copyable` `Handle` values. |
| 8 | **Dispatcher base and signals:** observers, `object_wait_one/many`, `object_wait_async` | `dispatcher.cc`+`.rs` ~1.7K, `wait_signal_observer` 0.4K, `syscalls/object_wait.*` | Required by everything that follows. |
| 9 | **Syscall layer:** entry/exit asm (syscall/sysret, svc, ecall), user-copy (`user_ptr` with fault recovery), dispatch table | `lib/syscalls` 9.9K. About 50 syscall families are defined in `zircon/vdso/*.fidl` | Generate the table from a Swift DSL or macro, not FIDL. |
| 10 | **Core IPC objects:** channel (message packets, buffer chains), port, event, eventpair, futex (with owner/PI), timer | channel 1.3K + `message_packet.rs` 1K + `buffer_chain.rs` 0.8K; `port_dispatcher` 1K; `futex_context` 1.3K; timer 0.5K; event/eventpair ~0.5K | Every Todhchai service depends on these. Ports carry IRQ, timer and signal packets. |
| 11 | **Job/process/thread objects, exceptions, policy** | `process_dispatcher` 2.2K, `thread_dispatcher` 1.7K, `job_dispatcher` 1.4K, `job_policy.rs` 0.9K, exceptions ~1.2K | Process isolation for drivers. Crash handling for apps and games. |
| 12 | **vDSO** (read-only shared ELF with syscall stubs, time functions, constants) and **userboot**; **bootfs** loaded by the croi loader from the ESP | `lib/userabi` 3.6K (`vdso.rs`, `userabi.rs`, `userboot/main.rs` 1.2K) | The handoff needs a v2 with a bootfs/ramdisk range, GOP framebuffer and cmdline. |
| 13 | **Resources** (MMIO, IRQ, IO port, SMC, root) and **interrupt objects** (bind to port, virtual, MSI) | `resource*` ~1.5K, `interrupt_dispatcher` 0.6K, `msi_*` 0.7K | Prerequisite for userspace drivers. |
| 14 | **BTI/PMT/IOMMU** | `dev/iommu` 9.6K. **This Fuchsia snapshot only ships ARM SMMU (`dev/iommu/arm_smmu/`) and a stub.** No VT-d or AMD-Vi source is present | GPU and NVMe drivers in userspace need IOMMU-isolated DMA. croi's scope (VT-d, AMD-Vi, SMMUv3, RISC-V IOMMU) goes beyond the reference, so those three need fresh design from the specs. |
| 15 | **Socket, FIFO, stream, IOB, counter, clock, debuglog** | socket 1.3K + `mbuf.rs` 1.5K; fifo 0.5K; stream 0.7K + `stream_size_manager` 0.9K; IOB 2K; clock 1.4K; debuglog 1.1K | FIFO suits block and GPU command rings. IOB (`zircon/vdso/iob.fidl`) is Zircon's shared ring-buffer object. **Counter** maps naturally onto Vulkan timeline semaphores. |
| 16 | **Pager** (userspace-backed VMOs) | `pager_dispatcher` 0.9K + `pager_proxy` 0.6K + `page_source` 1K | The filesystem page cache and mmap for BeFS. Can come after the first filesystem. |
| 17 | Later: ktrace/sampler, memory watchdog, restricted mode | `kernel/restricted*.rs` 0.6K | Restricted mode is how Starnix runs Linux binaries. It is a possible route to Linux and Proton game compatibility. |

**Minimum viable userspace** is items 0 through 12, including items 1–6 in a single-core first pass with SMP added right after. By Zircon's numbers that is about 60–70K LOC, but a croi port of the essential subset is more like 15–25K lines of Swift. The VM's eviction, compression and attribution machinery is most of the bulk and can wait.

---

## 3. Zircon userspace concepts: adopt, simplify or replace

| Concept | What it is in Fuchsia | Recommendation |
|---|---|---|
| **FIDL** | IDL plus compiler (`tools/fidl` 84K LOC, `sdk/fidl` 129K LOC of definitions). Wire format: 8-byte-aligned inline/out-of-line layout, a separate handle array, txid, ordinals, tables and flexible unions for evolution | **Replace the IDL; keep the wire-format ideas.** See below. |
| **Component framework** | `src/sys/component_manager` 76K LOC, CML manifests, capability routing, runners, realms | **Replace with something much smaller.** A capability-passing launcher: each process gets a namespace plus explicit handles. Write manifests as Swift values or a tiny declarative file. Skip the routing graph engine. Keep "no ambient authority". |
| **Namespace model** | Per-process name to channel table. No global root | **Adopt.** It is cheap, fits capabilities, and maps directly onto BeFS mounts and service directories. |
| **fdio/POSIX** | `sdk/lib/fdio` 18K LOC on top of a musl-derived libc (`zircon/third_party/ulib/musl` plus `sdk/lib/c`, about 88K LOC) | **Simplify.** Native Todhchai code talks to channels directly. A POSIX shim is still required for game ports (SDL, engines, tooling) and for the full Swift runtime (see §5). Build musl plus a small fdio-equivalent rather than writing your own libc. |
| **DFv2 (driver framework v2)** | `src/devices/bin/driver_manager` 29K, `sdk/lib/driver` 69K, driver runtime/dispatchers, bind rules, node topology | **Simplify.** Keep: driver host processes, a device-node tree, bind matching, and drivers that receive resource, IRQ and BTI handles. Drop: the in-process driver runtime transport, DFv1 compat, devfs layering. Bind rules can be Swift predicates evaluated by a Swift driver manager. |
| **bootfs / userboot** | Kernel starts `userboot` (`zircon/kernel/lib/userabi/userboot/main.rs`). It maps bootfs from the ZBI and launches the first process | **Adopt.** The croi loader also loads `\croi\bootfs.img` from the ESP and passes it in handoff v2. |
| **vDSO** | Only legitimate syscall entry. Time functions run in userspace | **Adopt.** It enforces the syscall ABI, gives a fast `clock_get_monotonic`, and lets you change syscall numbers freely. |
| **fuchsia.io** | `sdk/fidl/fuchsia.io` (~2.2K lines): Directory/File/Node, open flags, VMO for mmap, stream objects for read/write | **Replace with a BeFS-native protocol.** fuchsia.io has no indices, queries, live queries or rich typed attributes, and those are BeFS's identity. Keep its mechanics: a file is a channel to the server, `getBackingMemory` returns a VMO, and kernel `stream` objects provide syscall-speed read/write. Reference filesystems are in `src/storage` (fxfs 124K, minfs 21K, blobfs 31K, plus memfs and fshost). |
| **Magma** | GPU model: `sdk/fidl/fuchsia.gpu.magma/magma.fidl` (633 lines), `src/graphics/magma` 27K, MSDs in `src/graphics/drivers` (msd-intel-gen, msd-arm-mali, msd-virtio-gpu, ...). Client-side Vulkan ICD. The kernel-mode-like part runs as a userspace "system driver". Buffers are VMOs and are submitted over a channel | **Adopt the architecture, replace the transport.** The ICD/MSD split, buffers as VMOs, and semaphores as kernel objects are the right shape for userspace GPU drivers. Mesa can be retargeted (Fuchsia already builds Mesa ICDs against Magma). Add a fast submit path (FIFO or shared ring plus doorbell) instead of channel messages for every command buffer. |
| **sysmem** | `src/sysmem` ~40K. Buffer-collection constraint negotiation across GPU, display, camera, video and CPU | **Adopt the concept and simplify the implementation.** Without it, zero-copy GPU-to-display scanout breaks on tiling, modifier and alignment mismatches. |
| **Scenic/Flatland** | `src/ui/scenic` 115K, `lib/flatland` 53K. Flatland is a 2D layer tree, and clients present with acquire and release fences. The display coordinator sends Vsync as a FIDL event with acknowledgment throttling (`sdk/fidl/fuchsia.hardware.display/coordinator.fidl:30`) | **Replace** with a Vulkan compositor. Borrow Flatland's present credits, fences, frame scheduler (`src/ui/scenic/lib/scheduling`) and direct-scanout fast path. Make vblank a kernel-waitable object rather than a FIDL event (see §4). |

### What replaces FIDL in a Swift-native system

Use **Swift source as the IDL, with macros generating the stubs.** Sketch:

```swift
@IPCProtocol(ordinalBase: 0x1000, version: 3)
protocol Surface {
    func present(_ frame: borrowing FrameDesc, acquire: consuming Event) throws(IPCError) -> PresentToken
    @oneway func setTitle(_ s: borrowing InlineString<128>)
    @event func released(_ buf: BufferID)
}
```

The macro emits `SurfaceClient`/`SurfaceServer` and an encoder/decoder over `RawSpan` and `MutableRawSpan`, with **no allocation and no existentials.** Message types that carry handles are `~Copyable`: `Handle` closes in `deinit` and ownership moves with `consuming`. Decoded requests are `~Escapable` views borrowing the receive buffer, which gives zero-copy decode. Keep FIDL's proven wire rules: little-endian, 8-byte alignment, handles in a side array, txid plus a 64-bit hashed ordinal, and epitaphs.

What you must not lose:
1. **Evolution.** The game SDK needs ABI stability across OS versions. Provide `@flexible` enums and unions, and a "table" form with optional fields indexed by number. The macro should reject incompatible changes when checked against a recorded API baseline, much like Fuchsia's `@available` and versioning.
2. **Non-Swift clients.** The Vulkan ICD (Mesa, C) and C/C++ game engines must speak to the compositor and GPU services. Use a swift-syntax-based tool (not only the macro) that reads the same `@IPCProtocol` files and emits C headers and encoders. Only the encoding rules are a contract, so C bindings stay simple.
3. **Async.** Server dispatch should run on a port-driven loop, either a hand-written executor or an Embedded Swift `_Concurrency` custom executor. RT paths stay callback/loop-based, not `async`.

---

## 4. Kernel hooks a low-latency game desktop needs

Zircon already provides a lot of this:
- Deadline profiles (EDF with capacity and period).
- Priority inheritance through OwnedWaitQueue, and futex owners.
- Interrupt objects bound to ports, with timestamps.
- VMO cache policies, contiguous VMOs, BTI/PMT pinning.
- Counter objects, IOB shared regions, FIFOs.
- Memory-priority profiles (`ZX_PROFILE_INFO_FLAG_MEMORY_PRIORITY`).

Gaps and differences to add to croi's roadmap:

1. **User FP/SIMD state.** croi forbids FP in the kernel, but user threads need full XSAVE (AVX/AVX-512/AMX) on amd64, SVE/SME on arm64 and V on rv64, with save and restore on switch. AMX and SVE state is large, so use lazy or XFD-trapped allocation. Do this before the first thread runs user code. The rv64 baseline (`rv64imac`, `cmake/arch/rv64.cmake`) covers the kernel only, and userspace needs `rv64gcv`.
2. **Scheduling-context donation across IPC.** When a deadline-scheduled compositor calls a GPU driver over a channel, Zircon does not transfer the caller's deadline. Add donation along the lines of seL4 MCS: `channel_call` donates the caller's profile and budget until reply, or use a "reply-bound priority inheritance".
3. **Budget overrun notification.** A port packet when a deadline thread exceeds its capacity, so audio and compositor threads can detect overload instead of silently degrading.
4. **Vblank and present timing as a kernel object.** Something like a `DisplayTimeline` (or a counter plus timer) that the display driver advances from its IRQ handler with a hardware timestamp. The compositor waits on it directly through a port, with no driver-to-coordinator-to-client message hops. Also support **absolute-deadline timers with zero slack** on deadline threads (Zircon timers have slack policies; default those to none for RT profiles).
5. **Low-latency user interrupt delivery.** Keep port binding, but give drivers a way to wake a specific RT thread directly from the IRQ (an IRQ-to-thread fast path, no port queue). Also add MSI-X per-queue vectors as first-class objects.
6. **Shared-memory rings with futex doorbells as a blessed primitive.** Standardize on IOB or a simpler single-producer/single-consumer ring VMO plus a futex/eventpair wake. Use it for audio buffers (positions in shared memory instead of FIDL position notifications), input events, and GPU submit.
7. **GPU memory objects.** VMOs with **write-combining** and device-local physical backing (BAR/VRAM ranges as physical VMOs), huge-page (2M/1G) mappings, explicit pinning without eviction, and per-process accounting of GPU memory. Zircon's paging and eviction model (`vm/evictor.rs`, `page_queues.rs`) should be off by default for these.
8. **Timeline semaphores.** Make counter objects (`zircon/vdso/counter.fidl`) waitable at values ("signal when ≥ N") so they map one-to-one onto `VkSemaphore` timeline and sync files.
9. **Clock quality.** vDSO TSC/CNTVCT clock with published offset and rate, which Zircon has. Add a userspace-readable "next vblank" and "CPU frequency/power state" page for frame pacing.
10. **CPU isolation.** Reserve cores (no other threads, no timers or IRQs routed there) for the audio and game main thread. Zircon has CPU masks but no isolation mode.
11. **Priority-inheriting user mutexes from the start.** Futex with an owner field (Zircon has this, `futex_context`), so a Swift `Mutex` in the SDK gets PI for free.

---

## 5. Risks: Embedded Swift and full Swift in userspace

**Embedded Swift limitations** relevant to userspace:
- No reflection (`Mirror`), no `Codable`, and restricted existentials. Class-bound `any P` works in recent versions. For general `any P`, verify against 6.4 before relying on it.
- Untyped `throws` boxes `any Error`.
- No runtime generic instantiation. Everything is fully specialized, which means **code-size growth** and whole-module compilation only (`CMAKE_Swift_COMPILATION_MODE wholemodule`), so large services compile slowly.
- **No library evolution or resilience.** You cannot ship a binary-stable Embedded Swift framework. This rules out Embedded Swift as the public game SDK ABI. The SDK's stable boundary must be IPC protocols plus C-ABI libraries.
- **Concurrency in embedded is limited:** 6.4 ships `_Concurrency.swiftmodule` for embedded but **prebuilt `libswift_Concurrency.a` only for `x86_64-unknown-linux-gnu`** (`.../lib/swift/embedded/x86_64-unknown-linux-gnu/`). Todhchai would build it for its own triples. That runtime needs `malloc`, `clock_gettime`, `nanosleep`, stdio, and a few libstdc++ symbols (for example `_ZSt29_Rb_tree_insert_and_rebalance...`, `steady_clock::now`).
- Embedded userspace is otherwise cheap to host. `libswiftEmbeddedPlatformPOSIX.a` needs only `posix_memalign`, `free`, `putchar`, `memset`, `arc4random_buf` and the stack protector symbols (checked with `llvm-nm -u`). That is a few hundred lines on top of VMAR, VMO and cprng syscalls.

**Full Swift in userspace** is viable but is a real porting project. `swift_static/linux/libswiftCore.a` in 6.4 references about 160 libc symbols:
- malloc family and `malloc_usable_size`.
- stdio.
- libm, including long-double variants.
- pthread mutex, TLS keys, `pthread_getattr_np`.
- `__tls_get_addr` (ELF TLS).
- `dlopen`, `dlsym`, `dladdr`.
- `getauxval`, `mmap`, `mprotect`.
- Signals (`sigaction`, `sigaltstack`, `siglongjmp`).
- `clone`, `waitpid`, `execvpe`, `socketpair`. Most of these come from the backtracer and crash reporter, which can be stubbed.
- `_Unwind_Backtrace`.

`libswift_Concurrency.a` adds about 65 more symbols, `FoundationEssentials` about 100, and libdispatch about 290 (much of the Linux epoll and eventfd surface). Requirements for Todhchai:
1. A **musl-based libc** (follow Fuchsia's `zircon/third_party/ulib/musl` plus `sdk/lib/c` approach) with pthreads on futex and threads, ELF TLS set up by the loader, and `dl_iterate_phdr`.
2. A **dynamic linker** (or fully static linking first, which avoids dlopen; dynamic linking is needed later for Vulkan ICD loading).
3. A Swift compiler target. You can either add an OS to the Swift driver and stdlib build, or initially masquerade as `*-unknown-linux-musl` with a Linux-syscall-shaped libc. The second option is faster but leaks Linux assumptions. Note that LLVM already knows `*-unknown-fuchsia`, so mirroring it as a template is worth evaluating.
4. A Dispatch replacement or port that runs on Todhchai ports. Strongly consider skipping libdispatch and writing a native `TaskExecutor` over ports.

**Recommendation:** use two tiers.
- **Tier 0 (system):** kernel-adjacent services (userboot, driver manager, drivers, the RT paths of the compositor and audio, the filesystem) in Embedded Swift with croi's strict flags. They are small and predictable and allocation-audited.
- **Tier 1 (apps and SDK):** full Swift plus FoundationEssentials on musl, for applications, tools and game code that want existentials, Codable and async. Game engines in C/C++ reach the system through the generated C bindings.

Other risks:
- **6.4-specific features.** `@c @implementation` naming limits are already noted in CLAUDE.md, and Lifetimes is still experimental. `-enforce-exclusivity=unchecked` is fine in the kernel but should be reconsidered for userspace.
- **amd64 x87 trap.** It applies to Embedded userspace only if userspace reuses the kernel flags. Userspace needs SSE and AVX enabled, which needs an arch-cmake split between kernel and user.
- **Reference drift.** Zircon is mid-Rust-migration, so C++ and Rust versions may disagree. Pin a Fuchsia revision for porting references.

---

## Suggested near-term croi roadmap (shaped by Todhchai)

1. Handoff v2: bootfs range, GOP framebuffer, cmdline.
2. Interrupt controllers, a tickless timer and the monotonic clock.
3. PMM, then the kernel heap and slab.
4. Threads with PI wait queues, then the fair+deadline scheduler (design budget overruns and IPC donation in from day one).
5. SMP.
6. VMM phase (a): anonymous, physical and contiguous VMOs, VMARs, page faults, cache policy, huge pages.
7. Handles, dispatchers and signals.
8. Syscall entry, user-copy and the vDSO, plus user FP/SIMD state.
9. Channel, port, event, futex (with owners) and timer.
10. Process, thread, job and exceptions, then userboot.
11. Resources, interrupts and MSI, then BTI/PMT plus one IOMMU (SMMUv3 has a reference; VT-d does not), FIFO and counter (timeline waits), stream.
12. Pager, IOB and socket. The display-timeline object and IPC scheduling donation are croi extensions.
