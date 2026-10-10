# Taisce: a modern Be-style file system

The Be File System made typed attributes, indices and live queries part of
the file system, and the desktop was built on them: People files, mail as
files, query folders. Todhchai keeps that model and replaces the design under
it. Research notes: [research/systems.md](research/systems.md) §A, and
9front's gefs, cwfs and hjfs in
[research/9front-system.md](research/9front-system.md) §1–2.

Its name, *taisce*, is Irish for a store kept safe, a treasure
([research/irish-names.md](research/irish-names.md)). Its working name
was BeFS-NG.

## 1. What to keep, what to fix

**Keep from BFS:**
- typed attributes on every node, with small ones stored inline;
- declared indices on attribute names;
- an infix query language;
- **live queries**;
- node monitoring;
- MIME types as an attribute (`BEOS:TYPE`, which becomes `sys:type`).

**Fix.** Haiku's own BFS issues page says some of these can only be fixed by
starting a new file system:
- The index cannot do wildcard or substring queries efficiently.
- There is one fixed-size journal log.
- Metadata writes are effectively single-threaded.
- Space from files that were open when they were deleted is lost after a crash.
- The practical maximum file size is about 260 GB (fixed double-indirect runs).
- There are no checksums, snapshots, compression or encryption.
- Node monitoring does not survive a reboot, so indexers must rescan after a
  crash.
- Attributes written before an index existed are never back-filled.

**Avoid repeating APFS's mistake:** it checksums metadata but not data. Every
block is checksummed here.

## 2. Features by stage

| Stage | Features | Why this order |
|---|---|---|
| **S0 "BFS-plus"** | B+tree directories, extents, typed attributes (stored inline, then overflow keys), declared indices with automatic back-fill, query language v2, live queries, **persistent change journal**, metadata journaling (write-ahead log), nanosecond times, 64-bit sizes | Gets the BeOS user experience (Tracker, People, Mail, queries) working early, on a design simple enough to finish |
| **S1 "CoW"** | Copy-on-write for all metadata through physical block pointers; a 128-bit checksum (BLAKE3) on every block, stored in the parent pointer; transaction groups committed by superblock flip, with redundant header and footer copies; an intent log for fast `fsync`; lock-free readers with epoch-based reclamation | Crash consistency and integrity. The change journal, index format and transaction API stay the same |
| **S2 "Volumes"** | Containers holding many volumes that share space; snapshots (deadlists for reclamation) shown as dated directories; reflink clones for files and directories; zstd and LZ4 compression per extent (our implementations, from RFC 8878 and the LZ4 frame format); per-volume encryption (our AES-XTS, from FIPS 197 and IEEE 1619); incremental send and receive | Atomic system updates and backups. Gets the user-owned-machine story right |
| **S3 "Scale"** | Per-CPU allocation groups; multi-queue NVMe; batched TRIM; placement hints; parallel metadata commit | Performance on large NVMe arrays |

A checksummed copy-on-write file system with snapshots takes years: APFS,
ZFS and bcachefs each took more than five, and bcachefs was dropped from
mainline Linux in 6.18. The staging is how we manage that risk. S0 stays
usable and is not thrown away, because S1 replaces only the commit layer.

## 3. On-disk design (S1 target)

```
Container superblock ring (N copies, checksummed; highest valid TXG wins)
 ├─ Space manager     per-allocation-group free-extent trees + per-CPU reservations
 └─ Volume table      vol_id → {volume root pointer, keybag, snapshot tree root}

 Every pointer to a node is physical: {paddr, BLAKE3-128 of the node, birth txg}
 (ZFS and gefs style; decided in S1, docs/milestones/S1.md). There is no object
 map: moving a node rewrites its path to the root.

Volume FS tree   CoW B+tree, key = (inode_id: u64, kind: u8, sub_key)
   INODE   (ino, 0)                → mode, uid, times(ns), size, flags, inline attrs (≤ ~256 B total)
   DIRENT  (dir, 1, hash(name))    → child ino, type, name
   ATTR    (ino, 2, attr_name)     → type, value (≤ 2 KiB) | extent ref
   EXTENT  (ino, 3, file_offset)   → paddr, len, csum[], compression
 Index forest     one B+tree per declared index, key = (collated value, ino)
                  + optional trigram/prefix index per declared index (opt-in)
 Change journal   append-only (seq: u64, txg, ino, parent, reason bits, attr_name)
   (the FS tree, index forest and journal all hang off one volume root, so a
    snapshot captures all three and snapshot queries use the indices)

 Snapshot tree    snap_id/label → volume root + journal seq + birth txg
 Deadlists        (snap_id, birth_txg) → blocks freed while that snapshot lives  (gefs/ZFS style)
 Block-clone table  refcounts only for extents that were explicitly cloned (reflink)
```

- Attributes are separate B-tree keys, not a fat inode block (BFS) or a
  hidden attribute directory. Changing one attribute rewrites one leaf path.
- **The change journal is the backbone** for node monitoring, live-query
  catch-up, the indexer, backup and sync. A consumer stores the last `seq`
  it saw and resumes from there, after a reboot as well.
- Block size is 4 KiB and B-tree nodes are 16 to 64 KiB. Extents are 64-bit,
  and there is no indirect-depth limit.
- **Space reclamation without a general refcount tree.** When a snapshot
  exists, a freed block goes onto the deadlist of the newest snapshot that
  can still see it, keyed by the block's birth transaction group. Deleting a
  snapshot merges its deadlist into its neighbor's and frees what no one
  else can see. Only explicitly cloned extents carry refcounts. This is
  what gefs does, and it avoids a btrfs-style extent-ref tree being
  rewritten on every write.
- **A freed block waits before reuse.** It stays held through the group that
  freed it and deferred through the next, so a fallback to the previous
  superblock never finds it reused. It is then retired until no reader's
  snapshot can see it. So a full volume can have space that only commits
  give back: an operation that runs out while freed blocks wait commits
  twice, waits for readers, and runs again. Every operation either applies
  whole or changes nothing, so the commit in between is safe. A reserve of
  128 blocks is kept for commits alone, so a commit always has room for
  the catalog nodes it copies.
- **A failed write to the device stops writing.** If a commit fails on the
  device, or a failed change can't put back blocks it rewrote in place,
  what is in memory no longer matches what a later commit could safely
  build on. The volume then refuses changes (`readOnly`, EROFS) and keeps
  serving reads until it's mounted again, which finds the last commit
  that completed. Linux file systems go read-only on such errors for the
  same reason.

## 4. Storage engine: a CoW B+tree, not a Bε-tree (yet)

9front's gefs (about 12K lines) is a recent, small copy-on-write file
system built on a Bε-tree. Interior nodes buffer update messages that flow
down lazily, which suits workloads of many small scattered writes. That
describes Taisce's attribute updates: one indexed attribute change touches
the attribute key, the old and new index entries, and the journal.

**Decision:** S0 and S1 use a B+tree (copy-on-write from S1) with an
in-memory delta buffer per transaction group, which acts like a Bε root
buffer kept only in RAM. Reasons:
- Tracker and live queries are read-heavy, and every point read in a
  Bε-tree has to merge buffered messages at each level.
- Deleting an old index entry blindly needs the old value anyway, so an
  in-memory attribute cache is needed either way.
- Real Bε gains need nodes of hundreds of KiB or more. gefs's 16 KiB
  nodes get little benefit.
- With per-group batching, a CoW B+tree already rewrites each dirty node
  once per group, not once per operation, and on a desktop the working set
  is mostly in RAM.
- gefs has a single writer process, which repeats the BFS "metadata writes
  are single-threaded" flaw we want to fix.

We revisit a real Bε index forest in S3 if measurements show random
index-leaf writes dominate.

**Taken from gefs:**
- **The transaction API is a batch of messages:** insert, delete, and
  blind deltas such as "set mtime and size" or "bump version", applied
  atomically as one sorted batch. Designing S0's API this way lets the
  storage engine change later without touching callers.
- The checksum stored in the parent pointer, widened from gefs's 64-bit
  MetroHash to BLAKE3 truncated to 128 bits (ours, from its specification;
  decided in S1), because encryption and dedupe in S2 want a stronger
  hash.
- Epoch-based reclamation so readers take no locks, with back-pressure when
  reclaimed blocks pile up.
- The redundant header/footer commit around the superblock write.
- The shadow-model fuzzer (`fuzz.c`): apply random operations to the file
  system and to an in-memory model, and compare.

**Not taken:** the single writer; fixed 16 KiB data blocks with one key per
block (we use extents); the 512-byte cap on inline values (we inline
attributes up to about 2 KiB); log blocks rewritten in place outside the
checksum tree.

## 5. How snapshots appear

Plan 9 proved that snapshots should be ordinary directories:
`/n/dump/2026/1009/usr/...` from cwfs and hjfs, and any tool (`diff`, `cp`,
`bind`) works on them. gefs lists snapshots by label instead, and 9front's
`history` tool had to learn a second path pattern because of it. Taisce
offers both views, synthesized by the `fs` service rather than stored on
disk:
- `/snap/<volume>/<label>/` for tools. Labels carry their schedule, for
  example `home@hour.2026-10-09T14:00`.
- `/snap/<volume>/by-date/YYYY/MM-DD[.N]/` for people, plus a
  `yesterday`-style tool.

The protocol call is `Snapshot.open(label) -> Directory`, a read-only
directory channel the launcher can bind like any volume
(`/vol/home@2026-10-09`). Tracker's history browser and the backup and sync
services read the same tree.
- There are no magic `.snapshot` directories inside every directory. They
  confuse directory walkers and the indexer.
- Snapshot access is a granted capability, not a default. hjfs likewise
  refuses the dump to the `none` user.

## 6. Attributes, indices and queries

- **Attribute types:** `string` (UTF-8, normalized to NFC), `int64`,
  `uint64`, `double`, `time`, `bool`, `bytes`, `ref` (another node), `type`
  (MIME).
- **Namespaces:**
  - `sys:` for system attributes (type, app signature, capability grants);
  - `user:` for user attributes;
  - app-defined namespaces such as `Audio:` and `META:`, recorded in a type
    registry.
- **Indices are declarative.** `Index.declare("Audio:Artist", .string,
  collation: .caseFolded)` builds the index in the background and back-fills
  existing data. There is a small default set (`name`, `size`, `mtime`,
  `sys:type`), and anything else is opt-in, because every index adds writes.
- **Query language v2:**
  - It is a superset of the BFS infix syntax, so
    `((MAIL:status=="New")&&(sys:type=="text/x-email"))` still works.
  - It adds typed literals (`2026-10-09T00:00Z`, `4MiB`), ranges
    (`size in 1MiB..<1GiB`), `in [...]`, case folding (`~=`), and
    `order by`/`limit`.
  - Wildcards are fast when the term has an opt-in trigram index; otherwise
    the query scans.
  - At least one term must use an index, unless the caller asks for a scan
    explicitly.
- **Live queries:**
  - Results stream as `.queryUpdate(added|removed|changed)` events on the
    caller's loop, and each update carries the change-journal `seq`.
  - Notifications fire at in-memory commit, before the transaction group
    reaches disk. If a crash makes a notified change disappear, the consumer
    resyncs from the persistent journal.
  - A live query can be resumed from a `seq`.

## 7. The file system service and its interface

- The `fs` service is a tier 0 Embedded Swift process. It sits on the
  `block` service, which provides shared-memory submission and completion
  rings to the storage drivers.
- **Protocol:** a Todhchai-native `@IPCLibrary` protocol that replaces `fuchsia.io`.
  It extends the generic Node protocol (architecture §6) with `Directory`
  (batched listing with stat fields and requested attributes, streamed),
  `File`, `Attributes`, `Query`, `Index`, `Watch` (change journal) and
  `Snapshot`.
- **Data path:**
  - A kernel `stream` object gives read and write at syscall speed.
  - `backingMemory()` returns a pager-backed VMO for mmap.
  - An **async I/O ring** handles batched reads for asset streaming. Each
    request can set cache policy (cached, uncached/direct, read-once), and
    completions arrive on the app's port.
- **Not in the file system:** full-text, trigram-over-content and vector
  search. The **indexer** service reads the change journal, extracts content
  with translators, and keeps its own index files in the Spotlight model, so
  the file system's transactions stay cheap.

## 8. Trade-offs we have chosen

| Question | Choice | Cost |
|---|---|---|
| Live queries vs batched commits | notify at in-memory commit; journal seq lets consumers resync | a crash can "un-happen" a notification |
| Index write cost | small default index set; opt-in indices; batch per TXG | apps must declare what they query |
| Indices and snapshots | indices and journal live under the same snapshot root as the FS tree, so snapshot queries are indexed | snapshots keep old index blocks alive, using more space |
| Encryption and indices | per-volume keys; index keys encrypted with the volume key (deterministic per volume) | equality and ordering leak to someone holding raw disk plus volume metadata; no per-file key classes in v1 |
| Wildcards | opt-in trigram index; otherwise prefix-only plus scan | storage for trigrams |
| Compatibility | read-only Haiku BFS driver (later), from Giampaolo's book and our own reverse engineering of the format; FAT32/exFAT for the EFI partition and removable media, from Microsoft's published specifications; ext4 read-only (later), from its on-disk format documentation | — |

## 9. Tooling
- `mkfs.taisce`, `fsck.taisce` (scrub verifies every checksum from S1 on),
  and `taisce-fuse` for hosted mode on Linux. It speaks the `/dev/fuse` kernel
  protocol directly; there is no libfuse.
- A deterministic crash-test harness: record block writes, cut power at every
  prefix of the write log, then mount and check invariants. This runs in CI
  from S0 on.
- A query fuzzer that compares indexed results against a full scan, which
  catches the class of bug where Haiku's `MAIL:to=*` returned 202 of 17,000
  files.
- A shadow-model fuzzer in the style of gefs's `fuzz.c`: random operations
  are applied to both the file system and an in-memory model, and their
  states are compared after every step and after every simulated crash.
