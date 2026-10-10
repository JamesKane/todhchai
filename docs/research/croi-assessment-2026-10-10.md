# croi re-sync, 2026-10-10

A follow-up to [croi-assessment.md](croi-assessment.md) (2026-10-09), made
when N0 (M3's services, hosted) was done. Sources: `../croi` at `7c93414`
(K8b, 38 commits), with K8c in its working tree, uncommitted. The
requirement-by-requirement status is now in
[../croi-requirements.md](../croi-requirements.md); this note records what
changed and what it means for Todhchai.

## Where croi is

About 20,200 lines of Swift and 7,400 of C and assembly. K1 to K8b are done:
the kernel reaches user space on all three arches. userboot (Embedded
Swift) starts `userboot.next=` from a Zircon-format bootfs (default
`bin/launcher`), passing Zircon's processargs. User programs are C or
Embedded Swift ELF executables with a small runtime (stdout over debuglog,
a heap over VMOs).

The rest of M2 is K8c: the exit program (a channel pair, a VMO across it, a
port wait with a deadline timer, debuglog output) and the kernel budgets
measured from the trace under KVM. Its working tree adds profile objects
(`profile_create`, `object_set_profile` with an admission refusal) and the
trace's `RINGS` op. Measured so far under KVM: null syscall ~40 ns (budget
100), vDSO clock ~13 ns, an enabled trace event ~19 ns (budget 30).

croi's own status table in `docs/roadmap.md` is stale (it still lists K3
onwards as to do). Its milestone sections are current.

## What matches what N0 assumed

N0's `Sys` (`lib/sys`) was written against croi at K7b. Checked again:

- **Status codes:** croi's are a subset of ours (we also have
  `badSyscall` -13 and `unavailable` -28, both Zircon's). Lookup order
  (bad handle, wrong type, access denied) matches.
- **Signals and object types:** match. croi has types we don't name yet:
  log 12, resource 15, VMAR 18, profile 25, exception 29.
- **Port packets:** the same layout.
- **Flow ids and trace records:** `croi_flow_id`, the 32-byte record, the
  ring header and the kind ranges are as
  [../trace-format.md](../trace-format.md) says.
- **Startup:** compatible. Natively our launcher sends processargs (which
  carry PROC_SELF, THREAD_SELF and VMAR_ROOT) with the Startup channel as a
  `PA_USER0` handle; a program reads its `Startup` from that.

## Differences

1. **Default rights, croi against Zircon.** croi gives channels `duplicate`
   and ports `wait`. Zircon leaves both out (`rights.h`:
   `ZX_DEFAULT_CHANNEL_RIGHTS`, `ZX_DEFAULT_PORT_RIGHTS`). A channel end has
   one reader, and a port isn't a waitable object. Our hosted kernel uses
   Zircon's. One side has to change before M3: croi's own rule is Zircon's
   values, so croi is the side to fix.
2. **Rights we're missing.** croi has `getPolicy`/`setPolicy` (bits 10–11),
   `applyProfile` (19) and `manageVmo` (24), and its job default includes the
   policy rights (as Zircon's does). Our `Rights` lacks all four, and our
   `jobDefault` lacks the policy rights. Fix on our side.
3. **Calls whose shape differs natively.** These are hosted conveniences
   that a native `Sys` backend can't keep:
   - `Thread.start` takes a closure. croi's `thread_start` takes an entry,
     a stack and two arguments.
   - `Process.start` takes a `ProgramEntry` from the programs registered
     in `lib/hosted`. Natively the launcher loads an ELF into the new
     process itself, as userboot does. croi's `ProgramLoader` is kernel
     side; userboot's loader is the model.
   - `Process.create` returns the process. croi's returns its root VMAR
     as well, and a loader needs it.
   - `Vmo.map`/`unmap` use croi's interim `vmo_map` (43, "until VMARs").
     Natively that's `vmar_map`/`vmar_unmap` on the root VMAR, and unmap
     takes a length.

## What M3 needs that M2 doesn't give

M3's native exit boots to a framebuffer console and mounts Taisce on
virtio-blk. That needs croi work listed under "After M2":

- **Item 13, resources and interrupt objects**, for devmgr, PCI/ECAM and
  virtio. Today only the root, tracing and debuglog resources exist.
- **DMA:** at least item 14's BTI with no IOMMU (pin, return physical
  addresses) for virtio queues. User space also has no route to contiguous
  or physical VMOs, cache policy or cache operations: the kernel has them
  (K4b), but no syscall exposes them yet.
- **ACPI from user space (new requirement).** Our AML interpreter (A0) runs
  in devmgr. It needs the tables, plus its operation regions: SystemMemory
  over firmware ranges, SystemIO, and PCI config. croi refuses physical
  VMOs over RAM and firmware ranges, which is right as a default, so the
  tables and AML's memory regions need a resource-gated route.
- **The GOP framebuffer in user space (new requirement).** The handoff
  carries it, and the kernel maps it. Nothing hands it to userboot yet, as
  a resource or a physical VMO.

None of these block a first native step that needs only M2: N0's boot
running on croi with a block backend over a bootfs VMO (a ramdisk), and so
no drivers.
