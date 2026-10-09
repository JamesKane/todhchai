# The trace format, version 1

How Todhchai's processes record what they do, so `td trace`, `td bench`
and the debugger can read it ([performance.md](performance.md) §3–§4).
`lib/trace` (`Trace`) writes it and `lib/trace/reader` reads it. This file
is the contract. Records share croi's kernel trace layout (croi
requirement 18; NeoVectra ADR-0049, studied), so kernel and user records
merge into one timeline.

## Records

Every record is 32 bytes, little-endian:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 8 | `time` | The raw cycle counter (TSC, `CNTVCT_EL0`, rv64 `time`), not nanoseconds: ticks at `counter_hz` |
| 8 | 2 | `kind` | What the record is (below) |
| 10 | 2 | `cpu` | The CPU, where known; `0xffff` when not |
| 12 | 4 | `tid` | The thread: `(process << 12) \| thread index`, so a reader needs no table |
| 16 | 8 | `a` | Depends on `kind` |
| 24 | 8 | `b` | Depends on `kind` |

Kinds `0x0000`–`0x3fff` are croi's kernel categories (`sched` 1–6, `irq`
16–17, the kernel's MARK `0x70`). Kinds `0x4000`–`0x7fff` are user space's
(croi's `CROI_TK_USER_FIRST` to `CROI_TK_USER_LAST`). `0x8000`–`0xffff`
are reserved.

| Kind | Name | `time` | `a` | `b` |
|---|---|---|---|---|
| `0x4001` | MARK | when | the first 8 bytes of a text label | the next 8 |
| `0x4002` | ZONE | start | end, in ticks | name id |
| `0x4003` | FLOW | when | flow id | name id |
| `0x4004` | COUNTER | when | name id | the value (two's complement) |

- **ZONE.** A zone is written once, when it ends, so a crash loses only the
  zones still open. Zones on one thread nest by time.
- **FLOW.** Joins records across threads and processes. For an IPC call the
  flow id is computed by both ends from what they share (a hash of the
  channel's trace id and the transaction id, as croi's CALL and REPLY
  records do), so nothing extra travels with the message.
- **MARK.** Labels are UTF-8, NUL-padded, at most 16 bytes. `td bench`
  brackets each measured run with marks.

## The region

A traced process writes one region: on Linux a file it maps shared, so the
trace survives the process (a crash included) and a reader just opens it.
All offsets are from the region's start.

**Header, at 0 (4096 bytes):**

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic: `"tdtr"` (0x72746474) |
| 4 | 4 | version: 1 |
| 8 | 8 | `counter_hz`: the cycle counter's frequency, calibrated at start |
| 16 | 8 | `start`: the counter when recording began |
| 24 | 4 | process id |
| 28 | 4 | ring count |
| 32 | 8 | ring size in bytes, header included |
| 40 | 8 | the string table's offset |
| 48 | 8 | the string table's size |
| 56 | 8 | bytes of the string table used (atomic) |
| 64 | 8 | the first ring's offset |
| 72 | 4 | rings claimed so far (atomic) |
| 76 | 4 | flags: bit 0, circular (oldest records overwritten); else oneshot (newest dropped) |
| 80 | 8 | the categories enabled |
| 88 | 4008 | reserved, zero |

**The string table** holds the names records refer to. Each entry is a
4-byte length, then the UTF-8 bytes, padded to 4. A name's id is its
entry's offset within the table. Entries are appended and never change.

**Rings** follow, one per thread that has written. A thread claims the next
ring the first time it writes. Each ring is a 128-byte header, then
records. The header's first 64 bytes are croi's kernel ring header
(`croi_trace_ring_t`, confirmed with croi on 2026-10-09), so one reader
handles kernel and user rings:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `head`: records ever written (atomic) |
| 8 | 8 | capacity, in records: a power of two |
| 16 | 8 | records dropped (oneshot, when full) |
| 24 | 8 | the time of the first drop |
| 32 | 8 | the time of the last drop |
| 40 | 8 | `frequency`: the counter's Hz, as in the region header |
| 48 | 8 | `session`: the region's `start`, so rings from one recording go together |
| 56 | 4 | mode: 0 oneshot, 1 circular |
| 60 | 4 | cpu: `0xffffffff` for a thread's ring |
| 64 | 4 | magic: `"ring"` (0x676e6972) |
| 68 | 4 | the thread's `tid` |
| 72 | 56 | reserved, zero |

The newest record is at `(head - 1) & (capacity - 1)`. In circular mode
the oldest that can still be valid is at `head - capacity`.

Only the owning thread writes a ring, so writing takes no lock. It stores
the record, then publishes `head` with a release store. A reader loads
`head` with acquire, and in circular mode skips the oldest sixteenth,
which the writer may be overwriting (NeoVectra's rule).

## Categories

The enabled set is a 64-bit mask. A disabled trace point costs one relaxed
load of the mask and one predictable branch. User categories: bit 0
`app` (zones a program names itself), bit 1 `frame`, bit 2 `audio`, bit 3
`input`, bit 4 `ipc`, bit 5 `io`, bit 6 `mark`. The rest are reserved.

## Recording on Linux

`td trace record -o DIR [-c CATEGORIES] [--circular] -- PROGRAM ARGS`
runs a program with `TODHCHAI_TRACE=DIR` set. Each process that uses
`Trace` then writes `DIR/<pid>.trace`. `td trace print`, `td trace -s`
(per-name counts and percentiles) and `td trace -d` (two traces compared)
read the files.
