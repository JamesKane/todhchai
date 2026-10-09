# What Todhchai needs from croi

croi (`../croi`) boots on amd64, arm64 and rv64 under QEMU. Its K1 and K2
milestones are done: handoff, cache policy, PMM, kernel heap, SMP,
interrupt controllers, IPIs, the monotonic clock and tickless timers.
It has no threads, user mode, syscalls or kernel objects yet. croi's own
plan is `../croi/docs/roadmap.md`. It maps every item here onto its
milestones, records which items already have a Zircon design to follow,
and tracks each item's status.
The full assessment, with Zircon sizes for each component, is in
[research/croi-assessment.md](research/croi-assessment.md).

This file lists what Todhchai requires, in the order it needs them. Items
marked **(ext)** go beyond Zircon and should be designed in, not bolted on.

The machines these requirements are checked against, in order: the amd64
reference machine (i7-12700KF, Radeon RX 6750 XT), then the Orange Pi 6 Plus
(CIX Sky1) and the Radxa Dragon Q8B (SC8280XP). What the two boards demand
is recorded in [research/hardware-targets.md](research/hardware-targets.md);
the notes below marked *arm64 boards* come from there.

## 1. Path to the first user process

Minimum viable user space is items 1 to 12. Zircon's equivalent is about
60–70K lines. The estimate for the essential subset in Swift is 15–25K lines,
because the VM's eviction, compression and accounting can wait.

| # | Item | Notes for Todhchai |
|---|---|---|
| 1 | **Handoff**: bootfs range, GOP framebuffer, command line | The loader reads `\croi\bootfs.img`. The framebuffer is the first display until GPU drivers exist. *arm64 boards:* the early console must come from DBG2 when there is no SPCR (Sky1; Zircon's acpi_lite parses DBG2, 16550 only), and the Q8B's SPCR names a Qualcomm GENI UART (type 0x13; Zircon's uart library has a GENI driver) with a bad access width, which needs a per-board rule (§4). The arm64 entry must cope with arriving at EL1 under a vendor hypervisor (Q8B) as well as at EL2 (Sky1); croi already takes both, dropping from EL2 to EL1. The memory map's firmware carve-outs (DSP and codec regions, shared memory with DSPs) stay out of the PMM but must be reachable as physical VMOs (item 13). Zircon already works this way: its root-resource filter refuses MMIO resources over RAM (and over MMIO the kernel owns), so carve-outs must be non-RAM in the memory map |
| 2 | Interrupt controllers (APIC/IOAPIC, GICv3, PLIC/AIA), tickless one-shot timer, monotonic clock | Clock quality decides how accurate frame pacing can be. **Per-core timers can stop in deep idle** (both arm64 boards; on x86, the local APIC timer stops in deep C-states unless CPUID reports ARAT, which the 12700KF does): the timer layer needs a global always-on wake timer (an MMIO generic timer, or a board device such as the Sky1's GPT) and must know which CPU it can wake. **Interrupt routing is explicit policy**, never spread round-robin: interrupts that feed real-time threads go to a CPU that is kept out of deep idle (see §3 item 11). croi routes no device interrupt without an explicit affinity; Zircon can't set GICv3 affinity at all, and sends x86 MSIs only to the boot CPU. GIC errata (Arm 2941627 on the Sky1) are checked at bring-up; Zircon has no GIC erratum handling to borrow |
| 3 | PMM (with contiguous allocation and reclaim of HANDOFF/ACPI memory), kernel heap and slab | Scanout buffers need contiguous memory when there is no IOMMU. Contiguous allocation takes a **physical address limit** (the Q8B's display reads 32-bit addresses; Zircon's takes only an alignment). Low contiguous memory must survive long uptimes: on the Q8B it was gone after hours until a pool was reserved at boot. Zircon's design for this is a contiguous VMO created early plus *page loaning*: while the VMO is decommitted, its pages are lent to the system and reclaimed on commit (evicting or copying the borrowers, so commit is not instant). A pool is then not wasted memory. Zircon ships loaning off by default (`kernel.ppb.loan`) |
| 4 | Threads, wait queues, **priority-inheriting** owned wait queues, timers | PI from day one. The audio and compositor paths depend on it |
| 5 | Scheduler: fair plus EDF deadline profiles | The most important kernel item for Todhchai. **Capacity-aware from the start:** all three target machines mix core types (P/E cores on the 12700KF; three on the Sky1; two on the Q8B). Placement uses each core's capacity, and EDF admission counts budget in capacity-scaled time, so a deadline thread admitted on a big core is not silently moved to a little one. On the Sky1, work placed on the little cores ran at a quarter of the speed. Most of this is Zircon's existing design: a per-CPU processing rate, per-CPU normalized deadline utilization, an energy model, and `zx_system_set_performance_info`. The new part is admission: Zircon accepts every deadline profile and only checks a CPU's rate when placing a thread, logging oversubscription instead of refusing it. `_CPC` is AML, so capacity comes from the user-space power service through a privileged call, as in Zircon; until then croi uses core-type defaults (CPUID hybrid leaf, MIDR, PPTT) |
| 6 | SMP: AP bring-up, IPIs, TLB shootdown, per-CPU data | |
| 7 | VMM phase A: VMARs, anonymous/physical/contiguous VMOs, page faults, **cache policy (WC/UC)**, huge pages, **cache maintenance** (clean, clean+invalidate and sync on a VMO range, callable from user space) | Phase B (copy-on-write clones for ELF loading) comes next. The pager comes later. Many arm64 devices don't snoop CPU caches (`_CCA` 0: the Sky1's GPU, video codec and NPU), so user-space drivers need the cache operations, not just WC mappings. These are Zircon's `zx_vmo_op_range` cache ops and the vDSO's `zx_cache_flush`. Zircon gates invalidate-only behind a debugging option, because it can drop dirty cache lines. Clean+invalidate covers DMA from a non-coherent device |
| 8 | Handles, rights, koids, dispatchers, signals, `object_wait_one/many/async` | `Handle` is `~Copyable` in Swift |
| 9 | Syscall entry, user-copy with fault recovery, **vDSO**, **user FP/SIMD state** (XSAVE/AVX-512/AMX with lazy XFD; SVE/SME; RVV) | Userspace needs SIMD before the first user instruction. rv64 userspace needs `rv64gcv` |
| 10 | Channel, port, event, eventpair, futex **with owner (PI)**, timer (absolute deadline plus slack; RT profiles get zero slack) | Port packets carry IRQs, timers and signals: the "one wait" |
| 11 | Job, process and thread objects, exceptions, job policy | Process isolation for drivers and apps |
| 12 | userboot + bootfs | Starts the Todhchai launcher |

## 2. Needed for drivers and the desktop

| # | Item | Notes |
|---|---|---|
| 13 | Resources (MMIO, IRQ, IO port, root, **SMC**), interrupt objects (port-bound, virtual, **MSI/MSI-X per-queue vectors**, GICv3 ITS) | Userspace drivers. **SMC resource** (Zircon has `zx_smc_call`): an arm64 driver host can make the firmware calls its device needs. Zircon scopes the resource by SMCCC service number, so the Sky1's SCMI call (`0xc2000001`, a SiP call) would grant every SiP call. croi plans to scope by function-ID range instead. The Sky1 powers its GPU through SCMI over SMC; the Q8B authenticates DSP, codec and GPU firmware through TrustZone. Interrupt objects take an **affinity** set by policy (item 2) |
| 14 | BTI/PMT and one IOMMU (SMMUv3 has Fuchsia reference code; **VT-d and AMD-Vi do not**, so they need design from the specs) | IOMMU-isolated DMA for NVMe and GPU drivers; host-memory import for GPUs (F-108). **VT-d first**, for the reference machine. A BTI carries an **IOVA window** (the Q8B's codec may only use `0x25800000`–`0xe0000000`), a DMA address width (the Sky1's NPU drives 32 bits), and the device's **memory type**: Normal write-back for coherent devices, Normal non-cacheable for the rest, never Device (Device memory made the Sky1's NPU ten times slower). The IOMMU driver must keep firmware-required identity mappings (IORT RMRs, ACPI RMRR/DMAR reserved regions, the identity banks UEFI leaves on the Q8B) and must accept that some IOMMUs are firmware-owned or hypervisor-policed (§4). A **BTI with no IOMMU** exists for devices that have none (the Sky1's video codec, GPUs with their own MMU): it pins and returns physical addresses, and handing one out is a recorded trust decision. Zircon has the stub BTI for this. It has none of the rest: a BTI reports its IOVA space size but has no base window, width or memory type, no RMR/RMRR handling, and no VT-d driver |
| 15 | FIFO, **counter waitable at a value** (ext), stream, socket, clock, debuglog | Counters map one-to-one onto Vulkan timeline semaphores |
| 16 | Pager | Page cache and mmap for BeFS-NG |
| 17 | IOB or a simpler SPSC ring-VMO convention with futex doorbells | Standard shared-memory rings for input, audio, GPU submit and block I/O |
| 18 | ktrace and sampler | Feeds the system tracer |
| 19 | Debug syscalls: read/write thread state, exception channels, process memory access, start a process suspended, keep a crashed process frozen for post-mortem attach | `debugd` (architecture §16) |

## 3. Extensions for a low-latency game desktop (ext)

(Items 11 and 12 below come from the arm64 boards, and apply to the
reference machine's C-states and P/E cores too.)

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
   thread directly, with no port queue (audio DMA, display). Zircon already
   has this as `zx_interrupt_wait`: the thread blocks on the interrupt
   object and the handler wakes it with no port. The extension is that the
   interrupt object carries a scheduling context: the woken thread runs on
   it at once, with that context's deadline, as with IPC donation (ext 2).
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
11. **Deadline-aware idle.** croi owns CPU idle (it has to: entering and
    leaving power-down saves and restores CPU state, including SVE and
    EL2 state where present). The idle governor picks a state per CPU from
    the next timer and from a **wake-latency bound** derived from the
    deadline threads that may run there and the real-time interrupts routed
    there. The arm64 boards take 360–910 µs to leave core power-down against
    Todhchai's 100 µs p99 wake target, and the Q8B missed flips because
    vsync was routed to sleeping cores. A deadline profile therefore implies
    a latency bound on its CPUs, the way Linux's PM QoS does, without a
    separate interface. Idle states come from `_LPI`, which is AML. The
    user-space power service hands them to croi, and until it does croi
    idles only in states where the per-CPU timers keep running (WFI/HLT).
    Zircon idles arm64 with plain WFI (its static PSCI suspend state is used
    only for system suspend), has a simple MWAIT governor on x86, and has no
    broadcast wake timer, so this extension is new work.
12. **Frequency floor for admitted work.** EDF budgets are times, and times
    hold only at a known clock. Admission is checked against the capacity
    the CPU is guaranteed to have, and admitted deadline work raises a
    performance floor on its CPU's frequency domain (ACPI CPPC's minimum
    performance, or the SoC's equivalent) while it runs. The frequency
    *policy* itself lives in the user-space power service
    ([architecture.md](architecture.md) §8); croi enforces the floor. The
    CPPC registers come from `_CPC` (AML) through the power service. Zircon
    has x86 HWP and per-SoC arm64 frequency drivers, but no ACPI CPPC.

## 4. Hardware the kernel must not trust its own model of

From the arm64 boards ([research/hardware-targets.md](research/hardware-targets.md)):

- **Firmware-owned and hypervisor-policed hardware.** On the Q8B a
  hypervisor at EL2 resets the SoC, with no dump, on SMMU writes it doesn't
  expect, and PCIe sits behind an SMMUv3 the firmware reserves. croi's
  IOMMU and interrupt code must be able to leave hardware alone that it
  finds already configured, and take per-board rules about what it may
  touch.
- **Bus errors from user-space drivers.** A driver's MMIO access to a
  powered-off block can raise an SError or hang the bus outright. croi
  delivers a recoverable SError as an exception on the faulting process.
  (Zircon only counts SErrors; this is new.)
  Restartable drivers cover software faults; a hung bus still takes the
  machine down, and the design does not claim otherwise.
- **A watchdog early.** The SBSA generic watchdog (and its Sky1 refresh
  quirk) or the platform's, so a hang becomes a reset instead of a power
  cycle during bring-up. Zircon has only a devicetree-described one.
- **Per-board rules reach the kernel as data.** The console access width,
  the watchdog refresh method, GIC errata and the IOMMUs to leave alone are
  needed before user space runs. croi is ACPI-only, so it plans to read them
  from a file on the ESP keyed on SMBIOS / SoC ID, as part of its handoff.

## 5. Conventions for user space that inherit from croi

- Swift 6.4 toolchain, pinned through `.swift-version`. Strict memory safety
  is an error. Typed throws, `~Copyable`, `Span`, `InlineArray`, `Atomic`.
  Existentials and untyped `throws` stay out of hot paths.
- C boundary: declare in a header, implement with `@c @implementation`.
  Constants are typed C23 enums.
- Each arch's cmake configuration is split between kernel (no FP) and user
  (SIMD on).

How croi itself is written (including its use of Zircon as a reference)
follows croi's own directives, not Todhchai's principle 29.
