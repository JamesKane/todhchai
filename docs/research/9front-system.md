# 9front system study for Todhchai

Source: `/home/jkane/Projects/OS/9front` (read only). All paths are relative to that root. Line numbers are from the tree as checked out. Todhchai references are to `docs/filesystem.md` (BeFS-NG) and `docs/architecture.md` §4–5 and §15–16.

---

## 1. gefs: a CoW Bε-tree file server

### Size
`sys/src/cmd/gefs` has 11,918 lines of C:

| File | Lines | File | Lines |
|---|---|---|---|
| fs.c | 3260 | tree.c | 1631 |
| blk.c | 1129 | dat.h | 837 |
| snap.c | 694 | fuzz.c | 663 |
| pack.c | 531 | main.c | 507 |
| ream.c | 438 | check.c | 400 |
| dump.c | 374 | ctl.c | 306 |
| user.c | 243 | fns.h | 223 |
| cache.c | 180 | cons.c | 161 |
| load.c | 138 | hash.c | 136 |
| error.c | 67 | | |

The design paper is `sys/doc/gefs.ms` (1272 lines of troff). The man pages are `sys/man/4/gefs` and `sys/man/8/gefs` (the admin and ctl interface).

### On-disk format
- **Blocks.** Every block is 16 KiB (`Lgblk=14`, `dat.h:36-37`), so data blocks and tree nodes are the same size. The paper accepts that this is "smaller than optimal" for Bε nodes and "larger than optimal" for disk blocks, in exchange for a simpler block layer (`gefs.ms`, "For the sake of simplicity…"). There are no extents: each 16 KiB data block gets its own key, `Kdat(qid,off) → Bptr`.
- **Block pointers** are 24 bytes: `addr, hash, gen` (`Ptrsz=24`, `dat.h:58`). Pivot entries add a 2-byte fill count, which keeps sibling fill levels in the parent so nodes need no sibling pointers (`Pptrsz=26`, `dat.h:59`).
- **Checksums.** The hash lives in the parent pointer, so the tree is a Merkle tree. `readblk` checks `blkhash(b)` against `bp.hash` and raises `Ecorrupt` on a mismatch (`blk.c:115-125`). The hash is 64-bit MetroHash, which is not cryptographic (`hash.c:1-25`, `hash.c:118-136`). Log blocks are the exception: they are mutated in place and carry their own hash in the header (`blk.c:116-118`, and "Logs… are the only structure that is mutated in place, and therefore is not fully merkelized" in `gefs.ms`).
- **Keys.** The keyspace is flat and typed (`dat.h:104-123`):
  - `Kdat qid off → ptr`
  - `Kent pqid name → Xdir` (stat)
  - `Kup qid → parent Kent`
  - `Klabel`, `Ksnap` and `Kdlist`, which exist only in the snapshot tree
  - `Kconf`

  There are no directory blocks and no indirect blocks: a directory listing is a prefix range scan over `Kent(pqid,*)`. Size limits: keys ≤ 256 B (`Keymax`), inline values ≤ 512 B (`Inlmax`), names ≤ 245 B (`dat.h:46-57`).
- **Superblock.** There are two copies, at block 0 and at the last block. They hold the snapshot-tree root and hash, the snap deadlist, `nextqid`, `nextgen`, and the address and hash of every arena (`gefs.ms`, Appendix A).

### Bε mechanics (`tree.c`)
- **Pivot layout.** A pivot block is split in half: pivots and child pointers in one half, a message buffer in the other (`Bufspc = (Blksz-Pivhdsz)/2`, `dat.h:81-82`). Inside each half there is a sorted 2-byte offset table over unsorted variable-length data.
- **Message ops** (`dat.h:304-312`):
  - `Oinsert` and `Odelete`;
  - `Oclearb` and `Oclobber`, which are blind frees and removes;
  - `Owstat`, a blind delta to a dirent: size, mode, mtime, uid… (field bits in `gefs.ms`, "Messages");
  - `Orelink` and `Oreprev`, which re-chain snapshots.
- **Upsert.** `btupsert(t, msg, nmsg)` (`tree.c:1275`) stable-sorts a batch of messages.
  - If the root pivot's buffer has room, `fastupsert` copies the root and inserts the messages into its buffer, and nothing else (`tree.c:1218-1272`, path chosen at `1305-1309`).
  - Otherwise it walks down. At each full pivot, `victim()` picks the child that receives the most buffered bytes (`tree.c:1177-1215`). `flush()` then pushes that child's messages down a level, splitting, merging or rotating nodes as needed (`tree.c:1072`, `trybalance` at `1014`).
  - If not every message fits, it retries (`npull != nmsg → goto Again`, `tree.c:1380`).
  - The whole batch is atomic as long as it fits in the root buffer. This is what gefs uses for "data block + qid.vers + mtime + muid in one shot".
- **Lookup.** `btlookup` (`tree.c:1403-1458`) descends to the leaf, recording the path, and then applies the pending messages from each ancestor's buffer from the bottom up. So every point read pays a buffer search at each level. Range scans do the same merge in `btnext` (`tree.c:1522-1620`).
- **Write amplification in practice.** Every upsert copies the root and enqueues the copy to the syncer (`fastupsert`, then `enqueue(r)`). The old root, born in the same generation, goes straight to limbo, and the syncer skips writing blocks that were freed before it reached them (`checkflag(qe.b, Bfreed…)`, `blk.c:1119-1121`). The root buffer is what absorbs bursts of small writes.

### Snapshots, labels and forks
- A snapshot is `Ksnap(id) → {nref, nlbl, ht, gen, pred, succ, base, root bp}` (`gefs.ms`, Appendix A).
- Labels (`Klabel name → snapid`) are either mutable (they move forward on each sync, one per branch) or immutable.
- `fork base new` creates a new mutable branch from any snapshot (`sys/man/8/gefs:176`).
- Reserved labels are `main`, `adm`, `empty` and `dump` (`man/8/gefs:40-66`). `other` is a conventional unsnapshotted dataset for `/tmp` (`lib/namespace:38-41`).
- **Automatic snapshots.** A per-label `retain` schedule such as `60@m 24@h @d` drives them. The default is in `loadautos` (`fs.c:620-680`). `cronsync` creates labels named `main@minute.YYYY.MM.DD_hh:mm:ss` and deletes the oldest label in the ring (`fs.c:3206-3226`; format in `dat.h:148`).
- **Sync cadence.** The task proc syncs every 5 s (`fs.c:3228-3240`), so a "transaction group" is about 5 s.

### Deadlists (space reclamation without refcounts)
- When a block dies in tree `t`:
  - if it was born in the current in-memory generation, it goes to limbo and is freed immediately (`freeblk`, `blk.c:822-836`);
  - otherwise it is appended to the deadlist keyed `(snap, birth-gen)` (`killblk`, `snap.c:654-694`);
  - if it was born before the fork base of `t`, it is ignored and the base chain owns it (`snap.c:665-671`).
- **Deleting a snapshot** (`reclaimblocks`, `snap.c:292-345`):
  - deadlists whose birth generation is ≤ the previous snapshot are merged into the successor, a constant-time splice of head/tail pointers;
  - every other deadlist is freed wholesale;
  - the successor's deadlists born after the predecessor are freed too.
- So deletion touches only lists of blocks that really die. This is ZFS's sharded-deadlist algorithm, with a `base` field to stop double frees across forks (`gefs.ms`, "Snapshots").
- There are no reflinks or file clones, so no refcounts are needed.

### Crash consistency
- **Allocation.** Space comes from arenas, chosen round-robin and offset by block type (`gefs.ms`, "Block Allocation"; `pickarena`, `blk.c:129`). Each arena keeps an append-only allocation log (`logappend`, `blk.c:267`; `compresslog`, `blk.c:414`), replayed into an in-memory AVL tree at mount.
- **Commit** (`sync()`, `fs.c:82-230`):
  1. Under `mutlk`: update the snapshots for mutable mounts, `dlsync`, put a log barrier into each arena, and pack the arena headers h0/h1 and both superblocks.
  2. Write the arena headers, barrier.
  3. Write the superblocks, barrier.
  4. Write the arena footers (the h1 copies).
  5. `wrwait`, then free the old snap-tree deadlist through limbo.
- Headers and footers back each other up across the superblock write. A crash between steps 4 and 7 of the paper's sequence leaks space but cannot corrupt (`gefs.ms`, "Commit Protocol").

### Concurrency
- `main.c:428-487` reads `$NPROC`, clamped to 2..8, and starts:
  - one `mutate` proc, one `adm`, one `sweep`, one `tasks`, one `ctl`;
  - `nproc/2` `readio` procs;
  - `syncio` procs, one per sync queue;
  - one `runfs` dispatcher per connection.
- `runfs` (`fs.c:2581-2660`) routes messages:
  - `Tcreate`, `Twrite`, `Twstat`, `Tremove`, and `Topen` with OTRUNC or ORCLOSE go to the single mutator;
  - `Tattach`, `Twalk`, `Tread` and `Tstat` go to readers, hashed by fid.
- **One writer.** `runmutate` holds `mutlk` around each operation (`fs.c:2695-2750`). Metadata writes are serialized.
- **Epoch-based reclamation** (`blk.c:861-965`):
  - readers call `epochstart` and `epochend` (`fs.c:2752-2776`);
  - freed blocks go onto `limbo[epoch]` through a lock-free CAS push (`blk.c:804-820`);
  - `epochclean` advances a 3-slot epoch only when no active worker is in an older one;
  - if the limbo grows past `cmax/4`, it sleeps until the stalled reader finishes, which is how it applies back-pressure (`blk.c:895-907`).
- Readers take no locks on the tree.

### What's unfinished or missing
- The man page lists BUGS as "Yes" (`man/4/gefs:173`). A snapshot's mutability cannot be changed (`man/8/gefs:289-292`).
- `check.c` only checks; it never repairs.
- Missing features: compression, encryption, reflinks, extents, quotas, redundancy and self-heal (corruption is detected, not fixed), and parallel mutation.
- One FIXME: dirty blocks can sit in cache "until we clean up snap.c" (`cache.c:111`).
- Notably, `fuzz.c` (663 lines) runs a model-based fuzzer: random writes go both to the tree and to a shadow AVL model, and a scanner compares the two (`main.c:490-491`).

### Is a Bε-tree a good fit for BeFS-NG?
**Arguments for:**
1. Updating an indexed attribute means writing the ATTR key, deleting the old index key, inserting the new index key, and appending a journal record. These are four scattered keys, often in four different trees. In a Bε tree all four become messages in one atomic batch into the root buffer (`btupsert` with `nmsg`), with no read-modify-write of distant leaves. That is exactly the write-many-small-keys workload.
2. If the index forest and the change journal are key prefixes in the same tree, snapshots capture indices for free. This removes the "querying a snapshot scans" cost in `filesystem.md` §6.
3. CoW write amplification is the reason gefs chose Bε (`gefs.ms`, "reduce write amplification").

**Arguments against:**
1. Every point read (stat, attribute read, the old-value lookup needed to delete an old index entry) has to merge buffers at every level (`tree.c:1430-1452`). Tracker and live-query workloads are read-heavy.
2. The old index entry can only be deleted blindly if the old value is already known. In practice that needs an in-memory attribute cache for open nodes.
3. With 16 KiB nodes and half of each pivot given to the buffer, gefs gets little fanout and modest write optimization. Real Bε gains need nodes of hundreds of KiB to MB. That fights BeFS-NG's 16–64 KiB nodes and 4 KiB-block integrity model.
4. `tree.c` is the hardest 1631 lines in gefs: flush, split, merge and rotate with pulled messages.
5. gefs's single mutator repeats exactly the BFS "metadata writes are single-threaded" flaw that BeFS-NG lists to fix.
6. With per-TXG batching (BeFS-NG S1 commits a TXG by superblock flip), a CoW B+tree already rewrites each dirty node once per TXG, not once per operation. On a desktop where the working set is in RAM, most of the Bε advantage disappears.

**Verdict:** Bε is a reasonable fit but not a necessary one. For S0 and S1, use a CoW B+tree with a per-TXG in-memory delta buffer, which is effectively a Bε root buffer kept only in RAM. Revisit real Bε for the index forest in S3, if measurements show random index-leaf writes dominating.

**For Todhchai:**
- **Adopt:**
  - one typed flat keyspace with a key-type byte and big-endian packing, as `filesystem.md` already sketches;
  - an *upsert message vocabulary* with blind deltas (`Owstat`-style "set mtime/size/vers" and "bump version") applied atomically as a sorted batch. Design the S0 transaction API as "apply these N messages", so the storage engine can change underneath;
  - the hash stored in the parent pointer;
  - a model-based fuzzer with a shadow map. Add it to the BeFS-NG query fuzzer and crash harness;
  - epoch-based reclamation for lock-free readers, with back-pressure when the limbo grows;
  - deadlists keyed `(snap, birth-gen)` with a `base` for forks, for S2 snapshot deletion;
  - the two-phase header/footer commit idea, with redundant copies written on either side of the superblock write.
- **Adapt:**
  - use a 128-bit or cryptographic hash such as BLAKE3 or xxh3-128, not 64-bit MetroHash, because S2 encryption and dedupe want stronger hashes;
  - use deadlists for snapshot reclamation, and refcounts *only* for explicitly cloned extents (a block-clone table in the style of ZFS BRT). Do not build a general extent-ref tree;
  - put the index forest and journal under the same snapshot root. This gives snapshot queries for free, at the cost of index blocks retained by snapshots;
  - name snapshots by label plus schedule (`vol@hour.2026.10.09_14:00`).
- **Avoid:**
  - a single mutator proc;
  - fixed 16 KiB data blocks with one key per block. Use extents;
  - a 512 B inline value cap if attributes up to 2 KiB should be inline;
  - in-place-mutated log blocks outside the Merkle tree;
  - full Bε in S0 or S1.

---

## 2. The dump and how snapshots appear

- **cwfs.** The cwfs source is 15,153 lines. Its dump (`sys/src/cmd/cwfs/cw.c:1548-1610`) builds `yyyymmdd` with `datestr`, then:
  - finds or creates a 4-character year directory in the read-only WORM root (`found1`);
  - appends `mmdd` to it, with a suffix `mmddN` when there is more than one dump on the same day (`found2` and `found`, `sprint(tstr+8,"%ld",m)`).

  The result is an ordinary directory tree on the WORM. Mounting it with attach spec `dump` gives `/n/dump/2026/1009/usr/...`.
- **hjfs.** The hjfs source is 4,371 lines. `fsdump` (`sys/src/cmd/hjfs/dump.c:63-108`) does the same thing with `chancreat` of `%.4d`, then `%.2d%.2d[n]`, and a `copydentry` of the root. Attaching `dump` is read-only and refused to `none` (`hjfs/9p.c:48-55`).
- **Mounting.** `9fs dump` runs `mount -C /srv/boot /n/dump dump` (`rc/bin/9fs:33-34`).
- **Tools.** `yesterday` and `history` turn dates into paths. `history` probes for gefs (`test -e /n/$dump/adm`) and switches its glob to `/n/dump/main@day.*/file` (`rc/bin/history:75-82`).
- **gefs.** Attach spec `dump` synthesizes a directory (`Qdump`, `fs.c:277-292` and `1293-1297`). Reading it lists every `Klabel` (`readsnap`, `fs.c:2158-2228`). Walking a name under it opens that snapshot's mount in place (`fs.c:1430-1436`), and `..` from a snapshot root goes back to the dump directory (`fs.c:1421-1428`).
- **Mounting a single snapshot** uses its label as the attach spec: `mount /srv/gefs /n/x main@day.2026.10.09_00:00:00`. A leading `%` mounts permissively, adm only (`fs.c:1247-1250`, `man/4/gefs`).

The lesson: the snapshot view is *just a file tree* reachable through a mount spec. Every tool works on it (`diff`, `cp`, `bind /n/dump/2026/1009/sys/src /sys/src`). The date-shaped hierarchy (cwfs) is friendlier for humans than flat labels (gefs). gefs had to teach `history` a second glob because of that.

**For Todhchai:**
- **Adopt:** expose snapshots as read-only Directory channels, not as a special API. Add `Snapshot.open(label) → Directory` to the `fs` protocol, and let the launcher bind it like any volume (`/vol/home@2026-10-09`).
- **Adapt:** offer two synthesized views from the `fs` service:
  1. `/snap/<vol>/<label>/` for tooling;
  2. a date tree `/snap/<vol>/by-date/YYYY/MM-DD[.N]/` for humans and a `yesterday`-style tool.

  Both are generated from the snapshot tree, the way gefs's `readsnap` is, and not stored on disk. Labels should carry their schedule class (`@hour`, `@day`). Tracker's "time machine" and the backup and sync code read the same tree.
- **Avoid:**
  - magic `.snapshot` directories inside every directory, which confuse walkers and indexers;
  - giving apps snapshot access by default. Like hjfs, refuse `none`; make it a granted capability. A permissive mount (`%`) maps to an explicit admin capability, never to an ambient flag.

---

## 3. factotum, the auth agent

### Architecture
- `sys/src/cmd/auth/factotum` is 7,218 lines. About 18 protocol modules sit behind `prototab` (`fs.c:28-49`): p9any, p9sk1, dp9ik, rsa, ecdsa, pass, totp, wpapsk, chap, mschap, and others. `libauth` is 1,447 lines and `secstore` is 2,232.
- factotum is a 9P server mounted at `/mnt/factotum`. Its files (`fs.c:263-268`):

  | File | Mode | Purpose |
  |---|---|---|
  | `confirm` | `DMEXCL` | user approval of key use |
  | `needkey` | `DMEXCL` | requests for missing keys |
  | `ctl` | | add and delete keys |
  | `rpc` | `0666` | the protocol endpoint |
  | `proto` | | list of protocols |
  | `log` | | audit log |

- **Keys** are attribute lists such as `key proto=p9sk1 dom=x user=y !password=…`. Attributes whose names start with `!` are private. Reading `ctl` prints private attributes as names only, as `name?` (`attrnamefmt`, `util.c:904-918`; `keylist`, `fs.c:465`).
- **Self-protection.** factotum writes `private` and `noswap` to its own `/proc/n/ctl`, so it cannot be debugged and its memory cannot be swapped (`fs.c:191-210`).
- **secstore.** At start factotum forks `secstore -G factotum` and pipes the decrypted key file into `ctl` (`fs.c:174-185`). secstore uses PAK, a password-authenticated key exchange (`secstore/pak.c`, 344 lines), and keeps files AES-CBC encrypted on the server (`secstore.c:34-110`).

### The rpc protocol
The header comment is the spec (`rpc.c:1-30`). Each request is a paired write and read on one open fid of `rpc`:
- `start attrs` selects a key pattern and protocol;
- `read` returns the next message to send to the peer (`ok data`);
- `write data` accepts the peer's message, or replies `toosmall n`;
- `authinfo` returns the result;
- `attr` returns protocol info.

Replies are `ok`, `done [haveai]`, `needkey attrs`, `badkey`, `phase`, `toosmall` or `error`.

`fauth_proxy` (`libauth/auth_proxy.c:119-187`) is the whole client: a loop that shuttles bytes between factotum and the network fd. `dorpc` calls a `getkey` callback on `needkey` and retries (`auth_proxy.c:101-113`). At the end the client gets an `AuthInfo{cuid, suid, cap, secret}` (`include/auth.h:44-51`). That is a *session* secret, never the long-term key.

The client program never handles key material. It is a pipe between factotum and the peer.

### Approval
- **confirm.** A key carrying a `confirm` attribute makes `canusekey` queue a confirmation with a tag (`util.c:219-243`). The rpc read blocks. `confirmqueue` writes `confirm tag=N <public attrs>` to the `confirm` file (`confirm.c:113-140`). The UI writes back `tag=N answer=yes|no`, and that resumes the blocked rpc (`confirmwrite`, `confirm.c:50-110`).
- **needkey.** If `needkey` is open, a missing key blocks the rpc while a prompter supplies it, instead of returning an error (`rpc.c:126-130`).
- Both files are `DMEXCL`: only one UI agent can own approval.

### Other details
- **Becoming another user.** factotum writes capabilities to `#¤/caphash` (`util.c:618-650`, `mkcap`). A server that authenticated a client calls `auth_chuid`, which writes `ai->cap` to `/dev/capuse` to become that user (`libauth/auth_chuid.c:19-27`). The kernel enforces a one-time, factotum-minted right.
- **TLS from auth.** `tlsclient` and `tlssrv` run `auth_proxy(... "proto=p9any role=client")` and use `ai->secret` as the TLS-PSK (`tlsclient.c:113-119`, `tlssrv.c:86-105`). Authentication produces the transport key, so certificates are not needed between your own machines.
- **The exception.** `proto=pass` does hand passwords out (`pass.c:90`, through `auth_getuserpasswd`) for legacy clients.

**For Todhchai (keyring service shape):**
- **Adopt** the agent model wholesale. Keys live in `keyring`, a tier-0 process that debugd refuses to attach to (§15). Its memory is non-pageable or encrypted when paged.

  The protocol is `@IPCProtocol Keyring`:
  - `startSession(pattern: Attrs, role) → AuthSession` returns a new channel;
  - `AuthSession` has `next() → .send(bytes) | .need(count) | .done(AuthInfo) | .needKey(attrs) | .needConfirm`, and `feed(bytes)`;
  - `AuthInfo` carries the peer identity, a session secret (usable as a PSK or channel key), and an optional one-shot capability handle in place of `caphash`.

  Signing protocols (`sign(digest, keyPattern)`) return signatures, never keys.
- **Adopt confirm and needkey** as *exclusive* event channels that only the shell's trusted prompt process can hold. The shell renders `confirm` with the requesting app's identity. Add that identity, which Plan 9 doesn't have: the session records which namespace or process asked. A key's `confirm` attribute becomes a policy (`always | once-per-session | never`), stored as a typed BeFS-NG attribute on the key record.
- **Adapt secstore.** Keys at rest live in an encrypted keybag on the user volume, unlocked by the login secret. The same root derives volume keys (§16). Keep the attribute-pattern matching language (`proto=… dom=… user=…`).
- **Avoid:**
  - `proto=pass`-style secret export as a default. Make "reveal secret" a separate, confirm-gated capability;
  - text protocols parsed with tokenize. Use the typed IDL;
  - a single global `/mnt/factotum`. Each app gets a keyring session channel scoped by its manifest (which domains and protocols it may request).

---

## 4. Namespaces in the kernel

### Data structures and bind
- **Mount table.** Each process group (`Pgrp`) has a mount table: 32 hash buckets keyed by `qid.path` (`MNTLOG=5`, `MOUNTH`, `portdat.h:468-475`). Each `Mhead` holds an ordered list of `Mount{to, mflag, spec}`.
- **`cmount`** (`chan.c:654-783`) handles bind and mount:
  - `MREPL` replaces the list;
  - `MBEFORE` prepends;
  - `MAFTER` appends;
  - in a new union, the original directory is inserted as a member (`chan.c:741-754`);
  - binding a union *onto* a directory copies its members (`chan.c:705-712`);
  - `MCREATE` marks the member that receives `create` (`createdir`, `chan.c:1145-1166`).
- **Entry point.** `bindmount` (`sysfile.c:1032-…`) checks `canmount` only for `mount` (`sysfile.c:1040-1042`). `bind`, which rearranges names already reachable, is always allowed.

### Lookup cost
`walk()` (`chan.c:981-1140`) works in batches of up to `MAXWELEM=16` names:
- at each step it calls `findmount`, which takes a read lock, hashes, and compares `eqchantdqid` (`chan.c:878-911`);
- it calls the device's walk;
- *only if that fails* does it try each later union member in order (`chan.c:1046-1062`);
- it then checks every intermediate qid returned for a mount point (`chan.c:1083-1090`).

So the cost is:
- a hit in the first member: one walk;
- a miss: one walk per member, and each one is a 9P round trip if the member is remote;
- `/bin`, which unions `/$cputype/bin` and `/rc/bin` (`lib/namespace:25-27`), pays two walks for every rc-script exec.

**Union readdir** (`unionread`, `sysfile.c:343-386`) reads the members one after another, skips any member that errors, and does *not* remove duplicates.

### rfork and sandboxing
- `RFNAMEG` copies the namespace and `RFCNAMEG` starts it clean (`sysproc.c:88-94`; `pgrpcpy`, `pgrp.c:95-140`).
- `RFNOMNT` calls `devmask(pgrp, 1, "|decp")`, which blocks every `#` device except pipe, dup, env, cons and proc, and also blocks `#M`, so `mount` fails (`sysproc.c:30-35` and `119-120`; `canmount`, `pgrp.c:149-155`).
- The devmask is a one-way ratchet. Bits are only ever OR'd in (`pgrp.c:165-185`), and it is inherited even when the namespace is not copied (`pgrp.c:107-108`).
- 9front generalizes this as `chdev` through `#c/drivers` (`devcons.c:700-712`, `man/1/chdev`). `chan.c:1340-1350` refuses `#x` attaches for masked devices, and also blocks walks under them so they cannot leak which files exist.

### newns and /lib/namespace
- `newns` (`libauth/newns.c:33-94`) runs `rfork(RFENVG|RFCNAMEG)` and then interprets a namespace file with these commands: `bind`, `mount`, `unmount`, `clear`, `cd`, `chdev`, `.` (include), with `-a -b -c -C` flags and `$var` expansion (`newns.c:152-246`).
- It opens `/mnt/factotum/rpc` *before* building the namespace, with the comment "try for factotum now because later is impossible" (`newns.c:42`). Each `mount` authenticates through factotum (`famount`, `newns.c:131-150`).
- Errors are silent unless `newnsdebug` is set (`newns.c:202-204`).
- `/lib/namespace` is 46 lines that build a whole session (`lib/namespace:1-46`).

### mntgen and srv
- **mntgen** (242 lines) is a 9P server that synthesizes any directory name walked into it on demand. It is mounted on `/n` and `/mnt` (`lib/namespace:16-17`), so `mount x /n/anything` needs no `mkdir`.
- **srv.** `#s` lets a process post an open fd under a name. A write of a fd number to a new srv file captures the channel (`srvwrite`, `devsrv.c:603-640`). Auth fids are refused (`devsrv.c:631`). 9front adds hierarchical *boards* (`devsrv.c:28-43`), which give a namespace a private `/srv` (`bind -c #s$srvspec /srv`, `lib/namespace:6`).

**For Todhchai (launcher namespaces):**
- **Adopt:**
  - path → *ordered list* of channels, with `before | after | replace` and a `create` flag. This is the `Mount` list;
  - copy-on-fork of the table;
  - the ratcheting sandbox flag, called `sealed` below.
- **RFNOMNT analog.** A namespace has a `sealed` bit, inherited and never clearable. Once a namespace is sealed, `bind` (rearranging paths it already has) is still allowed, but attaching a *new* channel received from elsewhere is not. Without that rule, any channel handed over over IPC would break the sandbox. Seal app namespaces by default after the launcher builds them.
- **Adapt the union cost model.**
  - Resolve unions in the *client library* from the table, so the kernel or launcher does not need to be involved.
  - Cap union membership (for example 4) and let each member optionally publish a name list. Plan 9 tries members in order on every miss; a published list lets lookups be routed directly.
  - Merge and deduplicate union `readdir`, with first member winning, which Plan 9 does not do.
- **Namespace manifests.** Make them declarative and fail loudly. Don't copy newns's silent failure. Grab the keyring session before sealing, as newns grabs factotum before it rebuilds.
- **Avoid:** needing a mntgen at all. Mount points are table entries, so `/svc` and `/vol` are synthesized directly from the table.
- **Per-session service registry.** Model it on srv boards: a `/svc` registry where a process can post a channel only into its own board. Auth handshakes must never be postable (`devsrv.c:631`).

---

## 5. exportfs, rimport and rcpu: remote namespaces

- **exportfs.** `sys/src/cmd/exportfs` is 1,655 lines. It is a user-level 9P server that `chdir`s to a root and serves *its own namespace view* (`exportfs.c:76-104`).
  - Because the exported subtree spans many servers and devices, it must rewrite qids to keep them unique (`uniqueqid`, `io.c:419-456`).
  - It runs blocking operations in worker "slave" procs, so a stuck read does not stall the connection (`exportsrv.c:443-560`).
  - It supports `Tflush` (`exportsrv.c:744`).
  - `-P patternfile` filters what is exported (`pattern.c`), and `-R` makes the export read-only.
- **rcpu, rimport and rexport** are rc scripts of 96, 53 and 58 lines. They share `rconnect`, also an rc script.
  - `rconnect` runs `tlsclient -a` to the `rcpu` port (17019), which authenticates with p9any through factotum and turns the session secret into a TLS-PSK (`tlsclient.c:113-125`).
  - It sends an rc script, length-prefixed, that the server evaluates as the authenticated user (`rc/bin/service/tcp17019`, `man/1/rcpu:153-165`).
  - **rcpu** runs `exportfs -r /` locally over the TLS fd. The server mounts it at `/mnt/term` and binds `/mnt/term/dev/cons` (`rc/bin/rcpu:10-22`, `36-41`). So a "remote shell" is a remote process whose namespace includes the caller's terminal.
  - **rimport** runs `exportfs -r $tree` on the remote side and mounts the stream locally (`rc/bin/rimport:52`).
  - Notes (interrupts) travel over a pipe-backed `/mnt/cpunote` file (`rcpu:22-28`, `38-50`).
- **aan** (446 lines) is a reconnecting shim between the client and the network:
  - frames carry `{nbytes, msgno, acked}` headers (`aan.c:24-28`);
  - unacknowledged buffers are kept on a channel and replayed after a reconnect (`aan.c:149`, `214`, `323-330`);
  - the server side picks a port and passes it to the client (`rconnect`, `aanserver`);
  - it is enabled with `-p` and tolerates a disconnect of up to a day (`aan.c:20`).
- **Latency.**
  - A walk of up to 16 elements is one round trip (`MAXWELEM`).
  - Bulk reads are synchronous iounit-sized RPCs in a loop (`mntrdwr`, `devmnt.c:792-832`), so throughput is about iounit/RTT per reader. Over a WAN that is the well-known 9P weakness.
  - `mount -C` (MCACHE) adds a read cache (`devmnt.c:808-828`).
  - The design works because everything is a file, and degrades because nothing is pipelined.

**For Todhchai (namespace export bridge):**
- **Adopt:** an `exportd` that serves a chosen *subtree of the caller's namespace* over one authenticated stream, plus an import side that mounts it into a remote launcher namespace. Use cases: remote `/svc/<x>` inspection, `/svc/self`-style process tables, tracer streams, debugd, and files.
  - Authenticate through the keyring session secret and use it as the PSK, the same way tlsclient does.
  - Make it resumable, the way aan is: sequence-numbered frames, an ack watermark, and replay. Use QUIC if available, otherwise TLS with an aan-like layer.
  - Keep an explicit pattern allowlist and a read-only mode by default.
- **Adapt the transfer model.**
  - Pipeline reads with a window and use streaming `read(offset, maxBytes)` that returns many frames.
  - Batch walk+stat+readdir.
  - Make tracer output a push stream, not polled reads.
  - Map node identities (qids) per export, as exportfs does.
- **Avoid exporting:**
  - VMOs and shared-memory rings (audio, input, GPU, block);
  - raw handles that cannot be serialized;
  - the keyring rpc itself, except as an explicit, confirm-gated agent forward in the style of `ssh -A`;
  - debugd's write side (memory and register writes, breakpoints), unless a separate capability allows it;
  - the compositor;
  - anything latency-critical.

  The bridge is for inspection and files, not for real-time data paths.

---

## 6. The 9P protocol and lib9p

- **Messages.** There are 13 T/R pairs (`include/fcall.h:93-123`): version, auth, attach, flush, walk, open, create, read, write, clunk, remove, stat, wstat. `Terror` is illegal. Each has a man page (`sys/man/5`).
- **Fids** are 32-bit handles chosen by the client. `walk` clones a fid to a new one (`newfid`), so naming is client-driven. `NOFID` marks "no auth fid".
- **Tags** are 16-bit request ids, which allow many requests in flight per connection. `Tflush(oldtag)` cancels a request: the server must answer either the original or the Rflush, and never reuse the tag before that. lib9p implements this in `sflush`/`rflush` (`lib9p/srv.c:258-310`). gefs runs flushes under a per-tag-bucket write lock (`fs.c:2610-2616`).
- **Costs.**
  - `Tversion` negotiates `msize` and resets the session (gefs refuses anything before it, `fs.c:2603-2606`).
  - `Tattach(fid, afid, uname, aname)` costs one RTT and selects a tree. In gefs the aname selects the snapshot.
  - `Twalk` handles up to 16 names in one RTT and returns a qid for each element, so a partial result shows where the walk failed.
  - Opening a remote file is typically walk + open = 2 RTTs, and stat adds another unless it is cached.
- **lib9p.** The whole library is 2,804 lines (`srv.c` 948, `file.c` 425). A server fills in `Srv` callbacks (`include/9p.h:193-215`) and calls `postmountsrv` or `threadpostmountsrv`. lib9p handles fid and tag pools, version, flush bookkeeping and an optional in-memory `File` tree.
  - `lib9p/ramfs.c` is a complete RAM file system in **169 lines** with only four callbacks: open, read, write, create (`ramfs.c:114-119`).
  - `cmd/skelfs.c` is 257 lines and the standalone `cmd/ramfs.c` is 516.
  - `mntgen` is 242 lines and gefs's 9P layer is the bulk of `fs.c`.

**For Todhchai:** yes, make `/svc/<name>/` *9P-shaped*: a small generic Node protocol that every service can implement in about 150 lines with an SDK helper (the lib9p `File` tree equivalent). Map it onto channels, not a byte stream:

```
@IPCProtocol(id: "todhchai.node.Node", version: 1)
protocol Node {
  func walk(_ names: [Name]) throws -> (qids: [Qid], node: consuming Channel<Node>?) // ≤16 names, partial ok
  func stat(_ fields: StatMask) throws -> Stat           // typed attrs, BeFS-NG style
  func readdir(cursor: UInt64, max: UInt32, fields: StatMask) throws -> DirBatch
  func read(offset: UInt64, max: UInt32) throws -> Bytes  // pipelinable; server may stream
  func write(offset: UInt64, _ data: borrowing Bytes) throws -> UInt32
  func watch(since seq: UInt64) -> Channel<NodeEvent>   // replaces polling
  @since(2) func create(_ name: Name, kind: Kind) throws -> Channel<Node>
  @since(2) func remove() throws
}
```

- **Drop:**
  - fids: a channel handle *is* the fid, and dropping it is clunk;
  - tags and Tflush: use channel transaction ids plus a cancel message;
  - Tversion: use `@since`;
  - Tauth and Tattach: authority comes from the namespace and keyring;
  - wstat as a bag of fields: use typed setters.
- **Keep:**
  - multi-element walk with partial results;
  - the qid as `(path, version, type)` for cache validation;
  - the rule that inspection files are plain read and write text or typed records, so they are scriptable and exportable through the §5 bridge without translation.
- **Avoid:** making high-rate data flow through Node. Node should hand out the dedicated protocol channel, the way `/svc/audio/ring` would return a ring handle.

---

## 7. Build system and whole-system build

- **mk** is 3,555 lines (`sys/src/cmd/mk`). Its parallelism comes from `$NPROC` (`mk/run.c:189`). Templates do most of the work: `mkone` (72 lines), `mkmany` (89) and `mklib` (54) under `sys/src/cmd`. The entire gefs mkfile is the `OFILES` list plus `</sys/src/cmd/mkone` (`sys/src/cmd/gefs/mkfile`). There are 449 mkfiles under `sys/src`.
- **Top level.** `sys/src/mkfile` runs `mk all` over `$LIBS`, `ape`, `/acme`, `cmd` and `games`, and wraps the run in `date … date`. Whole-system build time has always been printed by default. A separate `kernels` target builds `9` and `boot`.
- **Static linking only.** Libraries are `.a` archives. Headers name their own library and source with `#pragma lib "libc.a"` and `#pragma src` (`include/libc.h:1-2`, `include/9p.h:1-2`), so the linker pulls libraries in automatically and no link lines are needed.
- **Header discipline.** Headers don't include other headers and there are no include guards; each library has one header (`sys/doc/comp.ms:155-180`). That bounds preprocessing cost.
- **Kernel configuration** is a plain device list (`sys/src/9/pc64/pc64`).
- **Size** (wc of `.c .h .s .y` under `sys/src`): 2,343,082 lines in 6,941 files, or 1.81 M without Ghostscript (`cmd/gs`, 533 k).

  | Area | Lines |
  |---|---|
  | `cmd` | 1.66 M |
  | — of which `audio` | 141 k |
  | — of which `aux` | 91 k |
  | — of which `ip` | 52 k |
  | — of which `upas` | 44 k |
  | — of which `cwfs` | 15.6 k |
  | — of which `gefs` | 11.9 k |
  | kernel `9/` (all ports) | 327 k |
  | — of which `port` | 70.7 k |
  | — of which `pc` | 107.7 k (most of it drivers) |
  | — of which `pc64` | 4.7 k |
  | — of which `ip` | 20.2 k |
  | `ape` | 75 k |
  | `libc` | 30.5 k |
  | `libsec` | 23.6 k |
  | `libmach` | 22.2 k |
  | amd64 C toolchain (`6c`, `6l`, `6a`, `cc`) | 27.7 k |

  Everything except gs and the games is a few hundred thousand lines of plain C, built by a compiler that does very little optimization. That is why a full 9front build is quick.
- I did not have a 9front machine to time a build, so no build-time number is reported. The tree's structure is the evidence that build speed was a design goal.

**For Todhchai:**
- **Adopt:**
  - track whole-OS build time (clean and incremental) as a CI metric printed at the top of every build log, the way `date…date` does, with a per-component breakdown;
  - static linking for tier-0 Embedded Swift services;
  - one-line component build files over shared templates (the mkone pattern);
  - a declared dependency next to the interface. `#pragma lib` corresponds to a Swift module that declares its link deps in one place.
- **Adapt:**
  - Swift's type checker and macro expansion (`@IPCProtocol`) are the build-time hazard; in Plan 9 it would be preprocessing. Budget per-module compile time, keep generated IPC code non-generic, and fail CI on regressions above a threshold;
  - record line counts by layer, as in the table above, next to build time, so growth is visible.
- **Avoid:**
  - a build that hides cost behind caches. Measure clean builds too;
  - letting one huge third-party component (gs, here 23% of all lines) be built as part of every OS build. Keep such ports out of the core build graph.
