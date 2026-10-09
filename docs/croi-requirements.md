# What Todhchai needs from croi

croi (`../croi`) currently boots on amd64, arm64 and rv64. It builds its own
page tables, installs exception vectors and halts. It has no PMM, threads,
user mode, syscalls or kernel objects yet. The full assessment, with Zircon
sizes for each component, is in
[research/croi-assessment.md](research/croi-assessment.md).

This file lists what Todhchai requires, in the order it needs them. Items
marked **(ext)** go beyond Zircon and should be designed in, not bolted on.

## 1. Path to the first user process

Minimum viable user space is items 1 to 12. Zircon's equivalent is about
60–70K lines. The estimate for the essential subset in Swift is 15–25K lines,
because the VM's eviction, compression and accounting can wait.

| # | Item | Notes for Todhchai |
|---|---|---|
| 1 | **Handoff v2**: bootfs range, GOP framebuffer, command line | The loader reads `\croi\bootfs.img`. The framebuffer is the first display until GPU drivers exist |
| 2 | Interrupt controllers (APIC/IOAPIC, GICv3, PLIC/AIA), tickless one-shot timer, monotonic clock | Clock quality decides how accurate frame pacing can be |
| 3 | PMM (with contiguous allocation and reclaim of HANDOFF/ACPI memory), kernel heap and slab | Scanout buffers need contiguous memory when there is no IOMMU |
| 4 | Threads, wait queues, **priority-inheriting** owned wait queues, timers | PI from day one. The audio and compositor paths depend on it |
| 5 | Scheduler: fair plus EDF deadline profiles | The most important kernel item for Todhchai |
| 6 | SMP: AP bring-up, IPIs, TLB shootdown, per-CPU data | |
| 7 | VMM phase A: VMARs, anonymous/physical/contiguous VMOs, page faults, **cache policy (WC/UC)**, huge pages | Phase B (copy-on-write clones for ELF loading) comes next. The pager comes later |
| 8 | Handles, rights, koids, dispatchers, signals, `object_wait_one/many/async` | `Handle` is `~Copyable` in Swift |
| 9 | Syscall entry, user-copy with fault recovery, **vDSO**, **user FP/SIMD state** (XSAVE/AVX-512/AMX with lazy XFD; SVE/SME; RVV) | Userspace needs SIMD before the first user instruction. rv64 userspace needs `rv64gcv` |
| 10 | Channel, port, event, eventpair, futex **with owner (PI)**, timer (absolute deadline plus slack; RT profiles get zero slack) | Port packets carry IRQs, timers and signals: the "one wait" |
| 11 | Job, process and thread objects, exceptions, job policy | Process isolation for drivers and apps |
| 12 | userboot + bootfs | Starts the Todhchai launcher |

## 2. Needed for drivers and the desktop

| # | Item | Notes |
|---|---|---|
| 13 | Resources (MMIO, IRQ, IO port, root), interrupt objects (port-bound, virtual, **MSI/MSI-X per-queue vectors**) | Userspace drivers |
| 14 | BTI/PMT and one IOMMU (SMMUv3 has Fuchsia reference code; **VT-d and AMD-Vi do not**, so they need design from the specs) | IOMMU-isolated DMA for NVMe and GPU drivers; host-memory import for GPUs (F-108) |
| 15 | FIFO, **counter waitable at a value** (ext), stream, socket, clock, debuglog | Counters map one-to-one onto Vulkan timeline semaphores |
| 16 | Pager | Page cache and mmap for BeFS-NG |
| 17 | IOB or a simpler SPSC ring-VMO convention with futex doorbells | Standard shared-memory rings for input, audio, GPU submit and block I/O |
| 18 | ktrace and sampler | Feeds the system tracer |
| 19 | Debug syscalls: read/write thread state, exception channels, process memory access, start a process suspended, keep a crashed process frozen for post-mortem attach | `debugd` (architecture §16) |

## 3. Extensions for a low-latency game desktop (ext)

1. **Display timeline object.** The display driver advances it from the vblank
   IRQ with a hardware timestamp, and it can be waited on through a port. A
   read-only page publishes the next vblank for each output.
2. **IPC deadline donation.** A `channel_call` from a deadline thread runs the
   server on the caller's scheduling context until it replies, as in seL4 MCS.
   Zircon does not transfer deadlines.
3. **Budget overrun notification.** A port packet tells a deadline thread when
   it exceeded its capacity.
4. **Admission test with a reason.** Requesting a deadline profile returns
   accepted or refused with a reason, checked against a per-user real-time
   budget, so no privilege is needed (F-215, Plan 9 EDF `admit`).
5. **IRQ-to-thread fast path.** An interrupt can wake a specific real-time
   thread directly, with no port queue (audio DMA, display).
6. **GPU memory accounting.** VMOs backed by device-local physical memory
   (BAR/VRAM ranges) or pinned memory are accounted to the owning process. One
   combined CPU+GPU budget per process, and a memory-pressure packet (F-109).
   Paging and eviction are off for these VMOs.
7. **Address-space views and JIT** (F-218). Atomic map-view and unmap-view
   inside a reservation, and per-thread W^X toggling within a reservation
   that has the right entitlement.
8. **CPU isolation.** Cores can be reserved for a job: no other threads, no
   timer or IRQ routing.
9. **Topology and power page.** Core types, cache sharing and current power
   state, readable without a syscall (F-204).
10. **Thread intent hint.** A `frame` intent that the scheduler can align to
    the display timeline.

## 4. Conventions for user space that inherit from croi

- Swift 6.4 toolchain, pinned through `.swift-version`. Strict memory safety
  is an error. Typed throws, `~Copyable`, `Span`, `InlineArray`, `Atomic`.
  Existentials and untyped `throws` stay out of hot paths.
- C boundary: declare in a header, implement with `@c @implementation`.
  Constants are typed C23 enums.
- Each arch's cmake configuration is split between kernel (no FP) and user
  (SIMD on).

How croi itself is written (including its use of Zircon as a reference)
follows croi's own directives, not Todhchai's principle 29.
