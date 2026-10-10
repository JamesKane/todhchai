# Performance: budgets, measurement and fixing violations

Principle 9 says performance numbers block releases. This file makes that
concrete. Every number Todhchai promises is a **budget**: a target, the
milestone that first enforces it, and a check that runs from that milestone
on. A violation fails the build. It is then profiled with the same tools
that measured it, and either fixed or re-decided in the open.

## 1. Why the measuring comes first

NeoVectra (`../NeoVectra`, `docs/00-overview.md` §8 and
`docs/20-tracing.md`) wrote its user-facing budgets down early and said they
were enforced in CI from M2. Nothing could measure them until its tracer
landed at M7. When `./build bench` ran over traces for the first time
(2026-10-09), three of the four budgets it could measure were over:

| Budget | Target | Measured |
|---|---|---|
| Spawn until `main` | 200 µs | 308 µs |
| Open and read a cached 4 KiB file | 5 µs | 230 µs |
| `ls` of 10,000 entries | 3 ms | 81 ms |
| Flight recorder overhead | 1% | 0.7% |

The causes found so far (its step 7a6, under way) are ordinary design costs
that piled up unseen over five milestones:
- a futex wake syscall on every 9P reply, whether or not anyone slept;
- a server round trip for every directory above a mount point;
- a walk plus a stat of every path prefix to look for symbolic links.

Each was easy to fix once a trace showed it. Each had also been built on by
four milestones of code before anyone looked.

So Todhchai follows two rules:

1. **A budget with no check running is not a budget.** A milestone that
   introduces a budget ships the measurement with it, or the budget moves to
   the milestone that can measure it.
2. **The tool that measures is the tool that explains.** Budgets are
   measured from trace events. A failing check leaves behind a trace that
   `td trace` opens, so the step from "over budget" to "here is why" needs
   nothing new.

## 2. Budgets

Each budget has a number, the milestone that enforces it, and where it is
measured. **QEMU** means under KVM on the reference machine (TCG numbers are
reported, not judged). **Hosted** means on Linux, on the reference machine.
**Hardware** means native on a machine from the hardware list.

Targets marked *(proposed)* are new here; most are taken from NeoVectra's
budgets for the same operations. They are decided at the milestone that
first measures them: a first measurement far from the target is a design
question, recorded in the roadmap's decisions, not a silent change.

### Kernel and IPC (croi)

| Operation | Target | From | Where |
|---|---|---|---|
| Null syscall round trip, amd64 | < 100 ns without mitigations; with them, published per CPU model *(proposed)* | M2 | QEMU, hardware |
| `channel_call` round trip, same core, with deadline donation | < 1 µs *(proposed)* | M2 | QEMU, hardware |
| Port wake from another core (event signal to `port_wait` returning) | < 2 µs *(proposed)* | M2 | QEMU, hardware |
| Shared-memory ring submit and completion, both sides busy, cross-core | < 300 ns, no syscalls *(proposed)* | M3 | QEMU, hardware |
| Futex wake with no sleeper | No syscall *(proposed)* | M3 | Counted in the trace |
| IRQ to the driver thread running | < 5 µs *(proposed)* | M3 | Hardware |
| Wake error, real-time intent, p99 | < 100 µs (architecture §8) | M2 in QEMU, M8 on hardware | QEMU, hardware |

### System

| Operation | Target | From | Where |
|---|---|---|---|
| Kernel entry to the text console | < 100 ms *(proposed)* | M3 | QEMU |
| Spawn a tier 0 program until its `main` runs | < 200 µs *(proposed)* | M3 | QEMU |
| Open and read a cached 4 KiB file through the namespace | < 5 µs *(proposed)* | M3 | QEMU |
| Live query update after a matching write | < 1 ms *(proposed)* | M3 | QEMU |
| N0, hosted: a channel call's round trip (its IPC flow, all four steps joined), a Node walk and read, a 4 KiB block read through the ring, launch to ready | Recorded per machine; a rise fails (no target until croi's numbers in QEMU) | N0 | Hosted |
| N0, hosted: a live query's update through the fs service after a matching write | < 1 ms | N0 | Hosted |
| The same read by a lock-free reader beside the writer (Taisce S1) | < 5 µs | S1 | Hosted, then QEMU (M3) |
| Reads with four lock-free readers at once, against one alone | at most 1.5× slower each | S1 | Hosted |
| `fsync` through the intent log, p99 (a 4 KiB write) | < 2 ms on the host's NVMe disk | S1 | Hosted |
| A group commit of 64 writes, p99 | < 20 ms on the host's NVMe disk | S1 | Hosted |
| Loading a machine's ACPI tables, load-time code run (587 KiB of AML), p99 | < 5 ms | A0 | Hosted, then QEMU (M3) |
| `_STA` on every ACPI device (162), p99 | < 1 ms | A0 | Hosted, then QEMU (M3) |
| Resident memory of all services at the text console | < 32 MiB *(proposed)* | M3 | QEMU |
| Shutdown to power off | < 500 ms *(proposed)* | M4 | QEMU |
| Kernel entry to the first desktop frame | < 1 s *(proposed)* | M8 | Hardware |
| Idle desktop: wakeups over 60 s with nothing changing | 0 per second (principle 9) | M4 | QEMU, hardware |
| Idle desktop: resident memory | < 256 MiB *(proposed)* | M6 | QEMU |
| Clean and incremental build time, per component | Published; a regression fails: over 10% and 0.25 s for incremental builds, over 20% and 2 s for clean builds (their noise is about ±6%) | M0 | Hosted |

### Apps and the desktop

The reference programs' criteria ([sdk.md](sdk.md)) are budgets, as are
the compositor's ([desktop.md](desktop.md) "Budget"):

| Operation | Target | From | Where |
|---|---|---|---|
| minimal: idle wakeups | 0 per second | M1 | Hosted, then QEMU (M4) |
| synth: underruns at 128 frames | 0 | M1 | Hosted, then QEMU (M4) |
| game loop: frame error p99 against present feedback | ≤ 1 ms | M1 | Hosted, then QEMU (M5), hardware (M8) |
| App cold start (minimal) to its first frame on screen | < 50 ms *(proposed)* | M4 | QEMU |
| Keypress to glyph: the terminal draws within | 1 ms of the key event, on screen within 2 frames *(proposed)* | M6 | QEMU; photon on hardware (M8) |
| text editor while typing | 0 dropped frames; 0 allocations in layout and paint | M6 | QEMU |
| terminal: termbench | within 2× of refterm | M6 | QEMU |
| file browser: 100k entries listed and sorted, warm | < 100 ms | M6 | QEMU |
| Hot reload of a 10K-line module | < 1 s | M7 | QEMU |
| Composition, all effects on, 4K, reference GPU | < 1.5 ms GPU time (0.3 ms with effects off) | M8 | Hardware |
| Input to photon | Measured and published, then a target | M8 | Hardware, with a photodiode rig |
| Frame-pacing misses with `balanced` vs deep idle off | No worse | M8 | Hardware |

### Swift costs

Swift hides some costs that C shows. These are counted, not timed, so they
are exact and don't depend on the machine:

| What | Budget | From |
|---|---|---|
| `swift_retain`/`swift_release` per frame in the reference programs' steady state | Recorded per program; a rise fails *(proposed)* | M1 |
| Heap allocations in real-time callbacks (audio, latch, input) | 0, checked at compile time where the SDK can (sdk.md) and counted at run time | M1 |
| Unspecialized generic calls on hot paths found by sampling | Reported per program | M7 |

### The tracer's own budgets

Measuring must not change what it measures:

| Operation | Target |
|---|---|
| A disabled trace point, kernel or user | One load and one predictable branch |
| An enabled kernel event | < 30 ns |
| An enabled user zone or span (begin plus end) | < 20 ns |
| Flight recorder (scheduling, IPC, IRQ, circular) | < 1% on the bench workloads; it stays off by default until this is met |
| Sampling at 1 kHz on every CPU | < 1% |
| `td trace -s` over 2 s of a busy desktop | < 1 s |

## 3. How budgets are measured

- **From traces.** A budget is the time between two trace events, a flow's
  length, or a count of events. `td bench` marks the trace at the start and
  end of each run, runs each workload enough times to judge a median and a
  p99, and reads the answer out of the trace. The harness and a person
  debugging a regression use the same measurements.
- **Hosted and native share the format.** The SDK's `Trace` module writes
  the same records on Linux as on croi, so the M1 programs' budgets are
  measured the same way before croi exists, and `td trace` works on a
  hosted run.
- **A failing run keeps its trace.** CI saves the trace of every run that
  misses a budget, beside the log, so the first step of the fix is opening
  it.
- **Each result is published.** Every budget's latest number, its history
  and the machine it ran on are in the CI report, as principle 9 requires.

## 4. What the tools must show

The profiling tools exist so that any violation can be explained. Their
design follows NeoVectra's 20 §3–§7, which works and whose costs are
measured:

- **Kernel events from croi:** context switches with what woke the thread,
  IPC calls and replies with donation, IRQs, page faults, futex waits with
  the waiter's return addresses, VMO commits. One fixed-size record format,
  one ring per CPU, written only by the kernel, read through a capability
  (croi-requirements item 18).
- **Flows across processes.** Almost every operation crosses processes, so
  per-process timing can't say where the time went. A flow id is computed
  by both ends from what they already share (the channel and transaction id,
  or the ring and slot sequence), so nothing extra is sent. The code `idlc`
  generates and the shared ring library write request and reply spans, so
  **every service is traced with no code of its own**.
- **User zones and marks** from the SDK's `Trace` module, in per-thread
  rings, stamped with the same clock as the kernel's events.
- **Off-CPU time:** why a thread wasn't running and what woke it.
- **Sampling, kernel and user stacks:** on the timer tick everywhere,
  including QEMU without a PMU, and on PMU counter overflow where there is
  one (cycles, cache misses, branch misses). Symbols come from the debug
  info index (architecture §16).
- **Contention and memory:** time waiting per lock, attributed to the
  caller's site; heap classes and commits over time per process.
- **GPU work** as spans on a GPU track, from timestamp queries, joined to
  the CPU flow that submitted it.
- **A flight recorder,** on by default once its overhead budget is met. It
  keeps the last seconds of the cheap categories. A crash, a missed frame
  deadline or an audio underrun saves it, so a hitch that already happened
  can still be explained.
- **Summaries and comparison.** `td trace -s` lists the slowest flows, the
  longest blocks with their wakers, and CPU time per process. `td trace -d`
  compares two traces, such as the last passing run and the failing one.
- **Who may read.** A process may trace itself. The whole-system trace is a
  capability the launcher grants (principle 20); sampling another process
  needs the right to inspect it.

## 5. When a budget is violated

1. **The build fails, where the numbers can be trusted.** Timings are
   only as good as the machine they're taken on. On a shared development
   machine (several agents and QEMU sessions at once), `td bench` reports
   every budget but fails nothing, and won't record a run taken while the
   machine was busy. On a quiet, dedicated machine (the build server,
   still to be set up), `--enforce` makes a regression or a missed limit
   fail the build. A milestone can't exit with a budget over on the
   enforcing machine. A check is never disabled to make a build pass.
2. **Profile it.** Open the failing run's trace, find the flow that missed,
   and compare it with the last passing run (`td trace -d`).
3. **Fix it, with evidence.** The change that fixes a violation cites the
   trace that showed the cause and the number after. A fix that only moves
   the cost (to another process, or to first use) isn't a fix.
4. **Or re-decide in the open.** If the target was wrong, the new target and
   the reason go in the roadmap's decisions. A budget is never loosened in
   the same change that would otherwise fail it.
5. **Regressions are budgets too.** Once a budget is met, a later rise of
   more than its noise margin fails the build even while it is still under
   target, so the margin isn't spent silently.

## 6. What this changes in the plan

- **croi:** the kernel trace and sampling (item 18) move up to the path to
  the first user process ([croi-requirements.md](croi-requirements.md) §1),
  with PMU access, so M2's exit can carry its budgets.
- **M0:** `td bench` and the budget report in CI, for build times first.
- **M1:** the SDK's `Trace` module and the hosted tracer, so the reference
  programs' budgets are judged from traces from the start.
- **M2:** the kernel and IPC budgets, measured over croi's trace.
- **M3:** the native tracer, flows in the IPC and ring code, sampling, the
  flight recorder and `td trace` (text, summaries, comparison). Every later
  milestone's budgets are measured with it.
- **M7:** the timeline viewer, the GPU track and remote tracing over the
  export bridge build on M3's tracer instead of introducing it.
