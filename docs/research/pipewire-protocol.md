<!-- SPDX-License-Identifier: BSD-3-Clause -->
2026-10-09

# PipeWire native protocol: a clean-room specification for a minimal playback client

This document specifies what a client must put on PipeWire's Unix socket, and what it must do in shared memory, to play audio without linking libpipewire. It is written in our own words from PipeWire's design documents. Where those stop, it draws on reading the 1.6.9 headers and sources to learn wire formats, struct layouts and behaviour. No PipeWire code is reproduced here. Byte layouts and offsets are given as tables. The two hex dumps were generated on the host from our own test inputs.

Target: PipeWire **1.6.9** (Fedora 44), with the socket at `$XDG_RUNTIME_DIR/pipewire-0`. The session manager is WirePlumber 0.5.18. All offsets are for x86-64 (LP64, little-endian).

## Tags

- **[V]** Verified. I read it in the cited documentation or source, or measured it on the host (struct offsets were found by compiling the 1.6.9 headers and printing `offsetof`; enum values were printed the same way; POD byte layouts were confirmed by hex-dumping PODs built by the 1.6.9 POD builder).
- **[U]** Unverified. It is my inference or general knowledge, and should be tested before we rely on it.

## Sources

Design documents (rendered, and their 1.6.9 sources):

- S1. Native protocol: https://docs.pipewire.org/page_native_protocol.html (source `doc/dox/internals/protocol.dox`, tag 1.6.9)
- S2. SPA POD: https://docs.pipewire.org/page_spa_pod.html (`doc/dox/api/spa-pod.dox`)
- S3. Graph scheduling: https://docs.pipewire.org/page_scheduling.html (`doc/dox/internals/scheduling.dox`)
- S4. SPA buffers: https://docs.pipewire.org/page_spa_buffer.html (`doc/dox/api/spa-buffer.dox`)
- S5. Release notes: `NEWS` at tag 1.6.9

Repository: https://gitlab.freedesktop.org/pipewire/pipewire, tag `1.6.9` (commit `8fa27cabdc6c0c1350c69c026af5850ef0af1e26`, 2026-09-17). Each file below is at that tag, for example https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/1.6.9/src/pipewire/private.h

- H1. `src/modules/module-protocol-native/connection.c`: framing, fd passing, version detection
- H2. `src/modules/module-protocol-native/protocol-native.c`: Core, Registry and Client marshalling
- H3. `src/modules/module-protocol-native.c`: server dispatch and its checks
- H4. `src/pipewire/core.h`, `client.h`, `node.h`, `port.h`, `link.h`, `keys.h`, `type.h`, `extensions/metadata.h`: opcodes, versions, keys
- H5. `src/pipewire/extensions/client-node.h`: ClientNode opcodes and version
- H6. `src/modules/module-client-node/protocol-native.c`: ClientNode marshalling
- H7. `src/modules/module-client-node/client-node.c`: the server side of a client node
- H8. `src/modules/module-client-node/remote-node.c`: libpipewire's client side (reference behaviour)
- H9. `src/pipewire/private.h`: `pw_node_activation` and the trigger rules
- H10. `src/pipewire/impl-node.c`: process, driver cycle, prepare/unprepare, IO handling
- H11. `src/pipewire/impl-link.c`, `buffers.c`, `impl-core.c`, `impl-client.c`, `resource.c`, `mem.h`, `src/modules/spa/spa-node.c`, `src/modules/module-link-factory.c`
- H12. `pipewire-jack/src/pipewire-jack.c`: a second client-node implementation that does not use pw_stream, and the closest model for ours
- H13. `spa/include/spa/pod/pod.h`, `pod/builder.h`, `utils/type.h`, `utils/defs.h`, `utils/atomic.h`, `node/io.h`, `node/node.h`, `node/command.h`, `buffer/buffer.h`, `buffer/meta.h`, `param/*.h`

Session manager: https://gitlab.freedesktop.org/pipewire/wireplumber, tag `0.5.18`. W1 is `modules/module-si-audio-adapter.c`, W2 is `modules/module-si-standard-link.c`, and W3 is `/usr/share/wireplumber/scripts/node/create-item.lua` (installed on the host).

---

## 1. Transport

### 1.1 Socket

- The client connects a `SOCK_STREAM` Unix socket to `pipewire-0`. libpipewire looks for it in `$PIPEWIRE_RUNTIME_DIR`, then `$XDG_RUNTIME_DIR`, then `$USERPROFILE`. [V S1]
- There is no handshake beyond the first message. **Core::Hello must be the first message.** [V S1, H1]

### 1.2 Message framing (protocol version 3)

Every message is a 16-byte header followed by `size` bytes. All header words are 32-bit and in native byte order (little-endian on our targets). [V S1, H1]

| Byte offset | Field | Meaning |
|---|---|---|
| 0 | `id` (u32) | Destination object: the proxy id on the client and the resource id on the server. They are the same number. |
| 4 | `size` (low 24 bits) + `opcode` (high 8 bits) | The word is `opcode << 24 \| size`. On little-endian, bytes 4–6 hold `size` and byte 7 holds `opcode`. |
| 8 | `seq` (u32) | Sender's message counter. |
| 12 | `n_fds` (u32) | Number of file descriptors that belong to this message. |
| 16 | payload | One POD (always a Struct), then optionally a footer POD. `size` covers both. |

- [V H1] The maximum `size` is 0xFFFFFF (24 bits). The sender refuses anything larger.
- [V S1] The S1 diagram draws `opcode` as the "first" 8 bits of word 2. That is true only if the word is read as an integer. **In memory on little-endian, the opcode is the last byte (offset 7).**
- [V H1] `seq`: libpipewire increments it for each message and masks it with 0x3FFFFFFF. The server records the last received `seq` but does not validate it (H3). Any increasing counter will do.
- [V S1, H1] Footer: an optional second POD after the payload. It is a Struct of pairs (Id opcode, Struct args). Footer opcode 0 means "registry generation" (Long) in both directions. A client that never sends a footer turns off the server's generation checks. A minimal client can ignore incoming footers and never send one.
- [V H1] Version detection: when the server sees id 0 with opcode 1 (Hello), it reads header word 3. If that word is ≥ 4, it assumes the legacy v0 protocol (an 8-byte header with no seq or n_fds). Our Hello therefore has to carry `n_fds` < 4. In practice it is 0.

Example: our Hello with version 4 is 40 bytes. These are the little-endian 32-bit words, built from the rules in §2. [V by construction against H13 rules]

```
00000000 01000018 00000000 00000000   header: id 0, opcode 1, size 24, seq 0, n_fds 0
00000010 0000000e                     Struct, body 16 bytes
00000004 00000004 00000004 00000000   Int (size 4, type 4) = 4, 4 bytes of padding
```

### 1.3 File descriptor passing

- [V S1, H1] Fds travel as `SCM_RIGHTS` ancillary data on `sendmsg`. Inside a payload, an fd is written as a POD of type **Fd** whose 64-bit value is the **index of that fd within this message's own fd list**, starting at 0. The receiver looks up `fds[index]`.
- [V H1] The sender deduplicates: the same fd appearing twice in one message gets one index.
- [V H1] An invalid fd is written as index `0xFFFFFFFF`. It is stored zero-extended in the Int64, and the receiver maps index 0xFFFFFFFF to "no fd". A receiver should treat 0xFFFFFFFF, −1, and any index ≥ `n_fds` as "no fd". This appears, for example, in SetActivation when a peer is removed.
- [V H1] At most 28 fds go with a single `sendmsg`. With more pending fds, libpipewire sends 4 data bytes per 28-fd batch. Receivers must therefore keep **a FIFO of received fds that is independent of message boundaries**, and hand `n_fds` of them to each message in order. A message's fds arrive no later than its first byte. The limit is 1024 fds outstanding per connection.
- [V H1] The server rejects a message whose `n_fds` exceeds the fds received so far with `EPROTO`.

### 1.4 Sync / Done and Ping / Pong

- [V S1, H2, H11 impl-core.c] **Core::Sync(id, seq)**, client→server: the server answers **Core::Done(id, seq)** with both values echoed, after handling everything sent before it. libpipewire sends `seq = 0x40000000 | message_seq`, but the server only echoes the value, so any value works. Use Sync as a barrier, for example after GetRegistry to learn that all Globals have arrived.
- [V S1, H11 resource.c, H7] **Core::Ping(id, seq)**, server→client: the client must reply **Core::Pong(id, seq)** with the same values, *after* it has processed every earlier event. Ping/Pong is not a liveness nicety. **The server uses it to complete asynchronous operations on a client node.** Each time the server calls a client node and gets an "async" result (setting a param, using buffers, the node's initial registration), it sends a Ping on the ClientNode's id and waits for the Pong before continuing. Ignore Ping and nothing gets created or linked.

---

## 2. SPA POD encoding

### 2.1 Common rules

- [V S2, H13] Every POD starts with an 8-byte header: `size` (u32, the body length in bytes, **not counting** trailing padding), then `type` (u32). The body follows, then zero padding up to a multiple of 8. A complete POD therefore occupies `8 + round_up_8(size)` bytes, and every POD starts 8-byte aligned.
- [V H13, measured] A **container's** `size` (Struct, Object, Array, Choice, Sequence) counts the full padded size of every child, including the last child's padding. A child's own `size` field never counts its padding.
- [V H13] All values are in native byte order. The validity bound is `size < 1 MiB` (`SPA_POD_MAX_SIZE`).

### 2.2 Basic type ids [V H13 `utils/type.h`]

| Id | Type | Body | Body `size` | Notes |
|---|---|---|---|---|
| 1 | None | none | 0 | Used for "null", for example an absent param or info. |
| 2 | Bool | i32 (0 = false, otherwise true) + 4 pad | 4 | |
| 3 | Id | u32 + 4 pad | 4 | An enum value. |
| 4 | Int | i32 + 4 pad | 4 | |
| 5 | Long | i64 | 8 | |
| 6 | Float | f32 + 4 pad | 4 | |
| 7 | Double | f64 | 8 | |
| 8 | String | bytes including the terminating NUL, then padding | strlen+1 | Must be NUL-terminated. Need not be UTF-8. |
| 9 | Bytes | raw bytes, then padding | n | |
| 10 | Rectangle | u32 width, u32 height | 8 | |
| 11 | Fraction | u32 num, u32 denom | 8 | |
| 12 | Bitmap | u8 bits, then padding | n | Deprecated and unused (S2). |
| 13 | Array | child header (u32 child_size, u32 child_type), then N packed child bodies, then padding | 8 + N·child_size | Children have no headers of their own and no per-element padding. |
| 14 | Struct | a sequence of complete PODs, each padded | sum of padded children | |
| 15 | Object | u32 object_type, u32 object_id, then properties | 8 + sum of padded properties | |
| 16 | Sequence | u32 unit, u32 pad, then controls | | Not needed for playback. |
| 17 | Pointer | u32 pointer_type, u32 0, then a native pointer (8 bytes) | 16 | Meaningless across processes. Never sent by us. |
| 18 | Fd | i64 index into the message's fd list (§1.3) | 8 | |
| 19 | Choice | u32 choice_type, u32 flags, child header (size, type), then N packed values, then padding | 16 + N·child_size | |
| 20 | Pod | | | Type marker used only in APIs. |

Other type-id ranges: 0x10000 pointer types, 0x20000 events (0x20002 = Node event), 0x30000 commands (0x30002 = Node command), 0x40000 object types. Object types (0x40000 + n): PropInfo 1, Props 2, **Format 3**, **ParamBuffers 4**, ParamMeta 5, **ParamIO 6**, ParamProfile 7, **ParamPortConfig 8**, ParamRoute 9, Profiler 10, ParamLatency 11, ParamProcessLatency 12, ParamTag 13, PeerParam 14, ParamDict 15. [V H13]

### 2.3 Object properties

[V S2, H13] Each property inside an Object is: u32 `key`, u32 `flags`, then one complete value POD (with its own header and padding). The keys depend on the object type (§4.4). Property flags: READONLY 1, HARDWARE 2, HINT_DICT 4, MANDATORY 8, DONT_FIXATE 16, DROP 32. We send 0.

### 2.4 Choice

[V H13] Choice types: None 0 (the first value is the value), Range 1 (default, min, max), Step 2 (default, min, max, step), Enum 3 (default, then alternatives), Flags 4. Flags is normally 0. Extra values beyond what the type needs are allowed and ignored.

### 2.5 Measured examples [V, dumped from PODs built with the 1.6.9 builder]

A Buffers param with `buffers = Range(2, 1, 8)`. The words are little-endian u32:

```
00000038 0000000f            Object, body 56
00040004 00000005            object_type ParamBuffers, object_id SPA_PARAM_Buffers (5)
00000001 00000000            prop key 1 (buffers), flags 0
0000001c 00000013            Choice, body 28 (unpadded)
00000001 00000000            choice_type Range, flags 0
00000004 00000004            child: size 4, type Int
00000002 00000001 00000008   values 2, 1, 8
00000000                     padding (counted in the Object's 56)
```

A Struct holding `Array<Id>[3, 4]`: `00000018 0000000e | 00000010 0000000d | 00000004 00000003 | 00000003 00000004`.

### 2.6 Dictionary convention

[V S1, H2, H6] Property dictionaries on the wire are written as `Struct( Int n_items, (String key, String value) × n )`. In ClientNode::Update and PortUpdate the `n_items` and the pairs sit **inline** in the info Struct, not in their own Struct (§4.3). Values beginning with `pointer:` are blanked by the receiver. The limit is 1024 items (client-node).

---

## 3. Startup messages

Interface type strings are `PipeWire:Interface:<Name>` [V H4]. Opcode 0 of every interface's *methods* is a local "add_listener" and never appears on the wire [V H4/H5].

### 3.1 Core (object id 0) [V S1, H2, H4]

The client's object ids: 0 = Core and 1 = Client are pre-allocated. **The client chooses every new id itself** (`new_id` arguments) and should allocate them densely from 2 upward [V S1; "densely" is U].

Methods (client → server):

| Op | Name | Payload Struct |
|---|---|---|
| 1 | Hello | Int version |
| 2 | Sync | Int id, Int seq |
| 3 | Pong | Int id, Int seq |
| 4 | Error | Int id, Int seq, Int res, String message |
| 5 | GetRegistry | Int version, Int new_id |
| 6 | CreateObject | String factory_name, String type, Int version, Struct(dict) props, Int new_id |
| 7 | Destroy | Int id |

Events (server → client):

| Op | Name | Payload Struct |
|---|---|---|
| 0 | Info | Int id, Int cookie, String user_name, String host_name, String version, String name, Long change_mask, Struct(dict) props |
| 1 | Done | Int id, Int seq |
| 2 | Ping | Int id, Int seq |
| 3 | Error | Int id, Int seq, Int res (negative errno), String message |
| 4 | RemoveId | Int id (the id may now be reused) |
| 5 | BoundId | Int id, Int global_id |
| 6 | AddMem | Int mem_id, Id type, Fd fd, Int flags |
| 7 | RemoveMem | Int mem_id |
| 8 | BoundProps | Int id, Int global_id, Struct(dict) props |

- **Hello version.** [V] S1 says "The version is 3". libpipewire 1.6.9 sends **4** (`PW_VERSION_CORE`, H4, H11 core.c). The server stores it as the Core resource version. With version ≥ 3 it binds our Client object at id 1 (H11 impl-core.c). With version ≥ 4 it reports bindings with **BoundProps**, and otherwise with BoundId (H11 resource.c). **Send 4.**
- [V H11 impl-core.c] On Hello the server destroys any earlier objects for this client, clears its memory pool, and sends Core::Info. Then, because Client 1 is bound, a Client::Info event should arrive on id 1 [U].

### 3.2 Client (object id 1) [V S1, H2, H4]

Methods: 1 Error (Int id, Int res, String), **2 UpdateProperties (Struct(dict))**, 3 GetPermissions (Int index, Int num), 4 UpdatePermissions (Int n, (Int id, Int perms)×n). Events: 0 Info (Int id, Long change_mask, Struct(dict)), 1 Permissions.

UpdateProperties is conventional right after Hello (S1's diagram shows it). Typical keys are `application.name` and `application.process.id`. [U: which keys the server overrides with values from socket credentials. Some security-related keys are reportedly protected.]

### 3.3 Registry [V S1, H2, H4]

`GetRegistry(version 3, new_id)` (PW_VERSION_REGISTRY = 3). Methods on the registry id: 1 Bind (Int global_id, String type, Int version, Int new_id), 2 Destroy (Int global_id). Events: **0 Global (Int id, Int permissions, String type, Int version, Struct(dict) props)**, 1 GlobalRemove (Int id). There is no end-of-list marker. Send Sync right after GetRegistry and wait for Done.

Globals we care about, with the property keys observed on the host [V via `pw-dump`]:

- `PipeWire:Interface:Node`: `node.name`, `media.class` (`Audio/Sink`), `object.serial`.
- `PipeWire:Interface:Port`: `node.id`, `port.id`, `port.direction` (`in`/`out`), `port.name` (e.g. `playback_FL`), `audio.channel` (`FL`), `format.dsp`.
- `PipeWire:Interface:Metadata` named `default`: key `default.audio.sink` with a JSON value `{"name":"…"}` for subject 0. Bind it with version 3. Metadata event 0 is Property (Int subject, String key, String type, String value).

### 3.4 Errors

[V H3] The server dispatches each message by `id` and `opcode`. An unknown id gives Core::Error `-ENOENT` "unknown resource". An opcode beyond the interface's method count gives `-ENOSYS`. A method with no handler gives `-ENOTSUP`. Missing permission gives `-EACCES`. A payload that fails to parse gives an error with the parser's code (usually `-EINVAL`, "invalid message"). These errors are sent and **dispatch continues**. A framing error (bad n_fds) is fatal to the connection. Core::Error's `id` names the object in error, and `seq` is the failing request's seq when known.

---

## 4. Creating a node we drive: client-node

### 4.1 CreateObject

[V H4, H5, H11 module-client-node.c, H8] `Core::CreateObject("client-node", "PipeWire:Interface:ClientNode", 6, props, new_id)`. `PW_VERSION_CLIENT_NODE` is **6**. Version 0 is rejected. With a version below 6 the server forces the legacy activation protocol (`client_version = 0`, H7). Below 4, no PortSetMixInfo events are sent.

The server creates the node **asynchronously**. It Pings the ClientNode id and registers the node global only after our Pong (H11 spa-node.c). Only then does it send BoundProps(our id, node global id), AddMem and Transport (H7).

Node properties (CreateObject `props`; ClientNode::Update can change them later). Each value is a string:

| Key | Our value | Effect |
|---|---|---|
| `node.name` | e.g. `todhchai-player` | Name. [V H4] |
| `node.description` | free text | Display name. [V H4] |
| `media.type` | `Audio` | Classification read by WirePlumber (W3). [V] |
| `media.category` | `Playback` | Classification. [U: any server-side effect] |
| `media.role` | `Music` | Used by role-based policy (WirePlumber). [U for exact effect] |
| `media.class` | Path A: **omit**. Path B: `Stream/Output/Audio` | Decides whether WirePlumber manages the node (§6.3). [V W3] |
| `node.autoconnect` | A: `false`; B: `true` | WirePlumber linking policy. [V W1] |
| `node.latency` | `128/48000` | Requested quantum/rate, parsed as `num/denom` by the server. [V H10] Requests, not forces, 128 frames. |
| `node.rate` | `1/48000` | Requested graph rate. [V H10] The host already runs at 48 kHz (`clock.allowed-rates = [48000]`, read from the `settings` metadata). |
| `node.force-quantum` | `128` (optional) | Forces the quantum while the node is active. [V H10] |
| `node.lock-quantum`, `node.always-process`, `node.want-driver` | optional | `always-process` implies `want-driver`. [V H10] |

**The audio format is not a property.** The server and WirePlumber read it from EnumFormat **param** objects (§4.4). Keys such as `audio.channels` and `audio.position` exist (H4), but I found no server code that parses them for a client node. [U whether WirePlumber uses them]

### 4.2 ClientNode methods (client → server) [V S1, H5, H6]

| Op | Name | Payload Struct |
|---|---|---|
| 1 | GetNode | Int version, Int new_id. Binds a Node proxy to our node (optional). |
| 2 | **Update** | see below |
| 3 | **PortUpdate** | see below |
| 4 | **SetActive** | Bool active |
| 5 | Event | Pod event (a Node event Object) |
| 6 | PortBuffers | Int dir, Int port_id, Int mix_id, Int n_buffers, then per buffer: Int n_datas, then per data: Id type, Fd fd, Int flags, Int mapoffset, Int maxsize. Only when we allocate buffers (§5.6). |

**Update (op 2).** One Struct with these members in order:

1. Int `change_mask`: bit 0 = params present, bit 1 = info present.
2. Int `n_params`, followed by `n_params` Object PODs (the node-level params).
3. Either a None POD (no info) or a nested Struct:
   - Int max_input_ports
   - Int max_output_ports
   - Long info_change_mask: FLAGS 1, PROPS 2, PARAMS 4
   - Long node_flags
   - Int n_items, then (String key, String value) × n_items. This is the property update, inline.
   - Int n_param_info, then (Id param_id, Int param_flags) × n.

Node flags [V H13]: RT 1, IN_DYNAMIC_PORTS 2, OUT_DYNAMIC_PORTS 4, NEED_CONFIGURE 0x20, ASYNC 0x40. The server checks only the dynamic-ports and async flags [V H10/H11 grep]. We send 0. Param-info flags: SERIAL 1 (toggle it to signal "changed"), READ 2, WRITE 4.

**PortUpdate (op 3).** One Struct:

1. Int `direction`: 0 = input, 1 = output.
2. Int `port_id`.
3. Int `change_mask`: bit 0 = params, bit 1 = info. **A change_mask of 0 removes the port.**
4. Int `n_params`, followed by the Object PODs (port params).
5. Either None or a nested Struct:
   - Long info_change_mask: FLAGS 1, RATE 2, PROPS 4, PARAMS 8
   - Long port_flags
   - Int rate_num, Int rate_denom
   - Int n_items, then (String, String) × n_items
   - Int n_param_info, then (Id, Int) × n

Port flags [V H13]: REMOVABLE 1, OPTIONAL 2, CAN_ALLOC_BUFFERS 4, IN_PLACE 8, NO_REF 0x10, LIVE 0x20, PHYSICAL 0x40, TERMINAL 0x80, DYNAMIC_DATA 0x100. We send 0. **Do not set CAN_ALLOC_BUFFERS** unless we implement PortBuffers.

[V H7] Port ids must be dense. A new port_id is accepted only if it is ≤ the current size of the server's port map. Use 0, 1, …. Updating an unknown port creates it. A param that is not an Object (or None where allowed) fails parsing. The limit is 4096 params per message.

**SetActive (op 4).** Bool. Send `true` after Transport has been received (libpipewire waits for the transport, H8). The server then adds the node to scheduling (H7 → `pw_impl_node_set_active`).

### 4.3 ClientNode events (server → client) [V S1, H5, H6, H7]

| Op | Name | Payload Struct | What the client does |
|---|---|---|---|
| 0 | **Transport** | Fd readfd, Fd writefd, Int mem_id, Int offset, Int size | Map our activation record: mem_id from AddMem, at offset/size (= 2312 bytes). Poll `readfd` (an eventfd) for wake-ups. `writefd` is signalled **only** when we drive the graph and the profiler flag is set (S1); a follower never signals it. |
| 1 | **SetParam** | Id param_id, Int flags, Pod param (Object or None) | Node-level param, for example Props or **PortConfig** (path B, §6.3). |
| 2 | **SetIO** | Id io_id, Int mem_id, Int offset, Int size | Node IO area. mem_id 0xFFFFFFFF clears it. Clock (3) points at our own activation's `position.clock`. **Position (7) points at the driver activation's `position`.** |
| 3 | Event | Pod | Node event (unused by us). |
| 4 | **Command** | Pod: an Object with type 0x30002 (Node command) and **id = the command** | Suspend 0, Pause 1, Start 2, Enable 3, Disable 4, Flush 5, Drain 6, Marker 7, ParamBegin 8, ParamEnd 9, RequestProcess 10, User 11. Body properties are normally empty. |
| 5 | AddPort | Int dir, Int port_id, Struct(dict) | The server asks us to add a port. We may refuse, as JACK does, by sending Core::Error on our ClientNode id. |
| 6 | RemovePort | Int dir, Int port_id | Same. |
| 7 | **PortSetParam** | Int dir, Int port_id, Id param_id, Int flags, Pod param (Object or None) | **Format (4)** fixes the format (None clears it and drops buffers). The server also sends Latency (15), Tag (17), PeerEnumFormat (18) and **PeerCapability (20)**. Ignore what we do not understand. |
| 8 | **PortUseBuffers** | §5.6 | Map the buffers. For output ports, **mix_id is 0xFFFFFFFF**: buffers belong to the port, not to a link (H7). |
| 9 | **PortSetIO** | Int dir, Int port_id, Int mix_id, Id io_id, Int mem_id, Int offset, Int size | One per link ("mix"). io_id Buffers (1, 8 bytes) or AsyncBuffers (10, 16 bytes). mem_id 0xFFFFFFFF clears. |
| 10 | **SetActivation** | Int node_id, Fd signalfd, Int mem_id, Int offset, Int size | Add a **target**: a node we must signal when we finish (§5.4). mem_id 0xFFFFFFFF with fd invalid removes target `node_id`. |
| 11 | **PortSetMixInfo** | Int dir, Int port_id, Int mix_id, Int peer_id, Struct(dict) | A link (mix) appears on our port, with the peer port's global id. peer_id 0xFFFFFFFF removes the mix. Sent only to ClientNode ≥ v4. |

There is **no** separate node-level UseBuffers. "UseBuffers" in S1 is event 8, PortUseBuffers (H5).

**Acknowledging.** After PortSetParam(Format) is applied, send a PortUpdate for that port whose params include the accepted Format (with the Format param-info flagged READWRITE) and the now-valid Buffers param. [V H8, H12 do this; H11 impl-link.c later reads the port's Format back, and a port that cannot return it makes a re-link fail with an error.] The server's waits are released by our **Pong**, not by the PortUpdate (§1.4).

### 4.4 The params we publish

Key and enum values were printed from the 1.6.9 headers [V H13]. Param ids: PropInfo 1, Props 2, EnumFormat 3, Format 4, Buffers 5, Meta 6, IO 7, EnumProfile 8, Profile 9, EnumPortConfig 10, PortConfig 11, EnumRoute 12, Route 13, Control 14, Latency 15, ProcessLatency 16, Tag 17, PeerEnumFormat 18, Capability 19, PeerCapability 20.

Format object (type 0x40003; id 3 for EnumFormat, 4 for Format). Keys: mediaType 1, mediaSubtype 2, audio format 0x10001, audio flags 0x10002, rate 0x10003, channels 0x10004, position 0x10005 (Array of Id). Values:

- media type audio = 1.
- subtype raw = 1, dsp = 2.
- sample formats: F32_LE (= F32 on LE) = 0x11B; F32P = DSP_F32 = 0x206; S16_LE = 0x103.
- channels: MONO 2, FL 3, FR 4.

Buffers object (type 0x40004, id 5). Keys: buffers 1, blocks 2, size 3, stride 4, align 5, dataType 6 (bitmask of 1 << data type), metaType 7.

IO object (type 0x40006, id 7). Keys: id 1 (Id: io type), size 2 (Int).

PortConfig object (type 0x40008, id 11). Keys: direction 1 (Id), mode 2 (Id: none 0, passthrough 1, convert 2, dsp 3), monitor 3 (Bool), control 4 (Bool), format 5 (a Format Object).

Latency object (type 0x4000B, id 15). Keys: direction 1, minQuantum 2, maxQuantum 3 (Float), minRate 4, maxRate 5 (Int), minNs 6, maxNs 7 (Long).

**Our output port: one per channel, in the graph's DSP format.** [V host] The host's sinks run their ports in DSP mode: `playback_FL` and `playback_FR` each advertise only `EnumFormat {audio, dsp, F32P}`, `IO [Buffers 8, AsyncBuffers 16]` and `Meta [Header 32]` (`pw-dump`). An interleaved stereo port would not intersect with them. So each of our ports, modelled on H12, publishes:

- `EnumFormat`: Object(Format, EnumFormat) { mediaType: Id 1, mediaSubtype: Id 2, format: Id 0x206 }.
- `Buffers`: Object(ParamBuffers, Buffers) { buffers: Range Int(2, 1, 8), blocks: Int 1, size: Int (max_frames × 4) (for example 8192 × 4), stride: Int 4 }. [V: the shape is H12's. U: the exact numbers are our choice.]
- `IO`: Object(ParamIO, IO) { id: Id 1 (Buffers), size: Int 8 }. Optionally a second one for AsyncBuffers (id 10, size 16).
- After Format arrives: `Format` = the same object as EnumFormat with id 4.
- Port info props: `port.name` = `output_FL`, `audio.channel` = `FL`, `format.dsp` = `32 bit float mono audio`. Param-info: EnumFormat READ, Meta READ, IO READ, Format WRITE (READWRITE once set), Buffers READ once a format is set (0 before). [U whether the server needs every one of these flags. H12 sets them like this.]

---

## 5. The real-time data path

### 5.1 Shared memory

- [V S1, H2, H11 impl-client.c] **Core::AddMem(mem_id, type, fd, flags)** registers a memory block. type is a `spa_data_type`, in practice MemFd = 2 (DmaBuf 3 is possible for video). flags are a subset of READABLE 1, WRITABLE 2, UNMAPPABLE 0x40. Everything that follows refers to the block by **mem_id**: Transport, SetIO, PortSetIO, SetActivation, PortUseBuffers.
- [V S1] **Core::RemoveMem(mem_id)**: drop the block. Unmap and close it once no mapping uses it.
- [V H11 mem.h] Mapping (offset, size) of a block: round the offset down to the page size, map `round_up(start_in_page + size, page)` bytes with `MAP_SHARED` and read/write access, and add the in-page start. Several mappings of one block (by different offsets) are normal. The activation records, IO areas and buffers of many nodes may share blocks.
- In libpipewire terms, a "pw_memblock" is just {id, type, fd, flags, size} plus refcounted mappings. It has no on-wire representation beyond AddMem. [V H11 mem.h]

### 5.2 Eventfds

[V S1, S3, H7, H9]

- **Our readfd** (from Transport) is written with 1 by whichever node makes our pending count reach 0 (an upstream peer or the driver). Read 8 bytes from it. A value greater than 1 means we missed wake-ups (an xrun).
- **Each target's signalfd** (from SetActivation) is ours to write (8-byte value 1) when we make that target ready.
- **writefd** (Transport) is for profiling only (§4.3).
- These are ordinary non-blocking eventfds, so they are compatible with epoll/io_uring. [V H7: created through the SPA system eventfd call]

### 5.3 `pw_node_activation` layout (1.6.9, x86-64; total 2312 bytes)

[V H9, measured with offsetof] S1 warns that the activation record "is currently an internal data structure that is not yet ABI stable". Pin these offsets to the server version (§7).

| Off | Size | Field | Who writes it |
|---|---|---|---|
| 0 | 4 | status (u32): NOT_TRIGGERED 0, TRIGGERED 1, AWAKE 2, FINISHED 3, INACTIVE 4 | All, by compare-and-swap (§5.4) |
| 4 | 4 | bit-field word: bit 0 version, bit 1 pending_sync, bit 2 pending_new_pos | Driver/transport. [U: bit order assumed from the SysV ABI, not measured] |
| 8 | 12 | state[0] = {i32 status @8, i32 required @12, i32 pending @16} | required: server. pending: driver reset, then decremented by triggering peers |
| 20 | 12 | state[1] (same shape) | unused by us |
| 32 | 8 | signal_time (ns, CLOCK_MONOTONIC) | the node that triggered us |
| 40 | 8 | awake_time | us |
| 48 | 8 | finish_time | us |
| 56 | 8 | prev_signal_time | driver |
| 64 | 184 | reposition (spa_io_segment) | |
| 248 | 184 | segment (spa_io_segment) | |
| 432 | 64 | segment_owner[16] (u32) | |
| 496 | 8 | prev_awake_time | |
| 504 | 8 | prev_finish_time | |
| 512 | 28 | padding[7], must be 0 | |
| 540 | 4 | **client_version**: write **1** after mapping | us |
| 544 | 4 | **server_version** | server (1 in 1.6.9) |
| 548 | 4 | **active_driver_id**: write the driver id from Position IO | us |
| 552 | 4 | driver_id | driver |
| 556 | 4 | flags: PROFILER 1, ASYNC 2 | server |
| 560 | 1688 | position (spa_io_position) | driver (in the driver's own record) |
| 2248 | 8 | sync_timeout | |
| 2256 | 8 | sync_left | |
| 2264 | 12 | cpu_load[3] (f32) | |
| 2276 | 4 | xrun_count | |
| 2280 | 8 | xrun_time | |
| 2288 | 8 | xrun_delay | |
| 2296 | 8 | max_delay | |
| 2304 | 4 | command: NONE 0, START 1, STOP 2 (transport) | |
| 2308 | 4 | reposition_owner | |

**Fields a minimal follower must touch:**

- Our own record: `status`, `awake_time`, `finish_time`, `client_version`, `active_driver_id`. Optionally state[0].status (it is read only for ClientNode < v5, H7).
- Each target's record: `state[0].pending` (atomic decrement), `status` (CAS 0→1), `signal_time`.

### 5.4 One cycle, follower side

[V S3, H9, H10, H12]

The driver begins each cycle as follows. For every node it schedules, it copies `required` into `pending`. **It skips any node whose `active_driver_id` ≠ `driver_id`**, and any node whose status is INACTIVE. It CASes every other node's status to NOT_TRIGGERED, increments `position.clock.cycle`, and then "triggers" its targets.

"Triggering" a target means:

1. Atomically decrement `state[0].pending` (sub-then-fetch).
2. If the result is 0: when the target's `server_version` ≥ 1, CAS the target's `status` from NOT_TRIGGERED to TRIGGERED, and **only on success** set its `signal_time` to now and write 1 to its eventfd. When `server_version` < 1, store TRIGGERED unconditionally, then write.

The reference implementation does these atomic operations with sequentially consistent ordering.

Our node, on each readable event on readfd:

1. Read the 8-byte counter.
2. CAS our `status` TRIGGERED → AWAKE. If the CAS fails, this was a stale wake-up: do nothing more.
3. Set `awake_time` = now.
4. Read the driver position (Position IO): `clock.duration` = frames this cycle (the quantum), `clock.rate` = 1/rate, `clock.cycle`.
5. Fill buffers and IO areas (§5.5).
6. Exchange our `status` with FINISHED (atomic xchg) and set `finish_time`.
7. If the old status was AWAKE (and the node is not async), **trigger every target** we hold from SetActivation. Targets include the sink we feed (link peer: output node → input node, H11 impl-link.c) and the driver (every follower points at its driver, S3, H10).

Start/stop [V H10, H12]:

- **Command Start**: set our status to FINISHED (it was INACTIVE as initialized by the server), then start polling readfd.
- **Pause or Suspend**: exchange status with INACTIVE. If the old status was NOT_TRIGGERED, TRIGGERED or AWAKE, trigger all targets once so the graph does not stall. Then stop polling.
- We never increment anyone's `required`. The server does that for remote nodes (H10 `activate_target` skips "exported" nodes).
- With `client_version` = 1, the server leaves our status alone (H10 `do_node_prepare`).

**Position IO.** On SetIO(Position), map it and **write `position.clock.id` into our `active_driver_id` (offset 548)**. Without this the driver silently skips us forever. [V H10 `pw_impl_node_set_io`, H12] Position lives at offset 560 of the driver's record, but always use the mem_id/offset given by SetIO.

### 5.5 IO areas and where samples go

[V H13 io.h, H7, H12]

- `spa_io_buffers` (8 bytes): i32 status @0, u32 buffer_id @4. Status values: OK 0, NEED_DATA 1, HAVE_DATA 2, STOPPED 4, DRAINED 8.
- `spa_io_async_buffers` (16 bytes): two spa_io_buffers. Writers use slot `(cycle+1) & 1` and readers use `cycle & 1`. For an output port that means slot `[(cycle+1)&1]`.
- `spa_io_clock` (160 bytes):

  | Off | Field |
  |---|---|
  | 0 | flags (FREEWHEEL 1, XRUN_RECOVER 2, LAZY 4, NO_RATE 8, DISCONT 16) |
  | 4 | id |
  | 8 | name[64] |
  | 72 | nsec |
  | 80 | rate {num, denom} |
  | 88 | position (u64) |
  | 96 | duration (u64) |
  | 104 | delay (i64) |
  | 112 | rate_diff (f64) |
  | 120 | next_nsec |
  | 128 | target_rate |
  | 136 | target_duration |
  | 144 | target_seq |
  | 148 | cycle |
  | 152 | xrun |

- `spa_io_position` (1688 bytes): clock @0, video_size (40) @160, offset (i64) @200, state (u32: STOPPED 0, STARTING 1, RUNNING 2) @208, n_segments @212, segments[8] (184 each) @216.
- `spa_io_segment` (184 bytes): version @0, flags @4, start @8, duration @16, rate (f64) @24, position @32, bar (64) @40, video (80) @104.

Per cycle, for each output port, with frames = clock.duration:

1. Pick a buffer. If our IO slot still says HAVE_DATA (the consumer has not taken it), reuse that buffer id. Otherwise take the next free one in round-robin. [V: the policies of H12 and stream.c]
2. Write `frames` f32 samples for this channel into the buffer's data (§5.6).
3. Set that data's chunk: offset 0, size = frames × 4, stride 4, flags 0.
4. Store buffer_id, then status = HAVE_DATA, into the IO slot of **every mix** on the port. (Usually there is one, from PortSetIO.)

### 5.6 How PortUseBuffers describes buffers

[V S1, H6, H7, H8, H11 buffers.c]

Payload: Struct(Int dir, Int port_id, Int mix_id, Int flags, Int n_buffers, then for each buffer:

- Int mem_id, Int offset, Int size: the buffer's region in a block
- Int n_metas, then (Id meta_type, Int meta_size) × n_metas
- Int n_datas, then (Id data_type, Int data, Int data_flags, Int mapoffset, Int maxsize) × n_datas)

Limits: 64 buffers, 16 metas, 256 datas. flags bit 0 (ALLOC) means "the client allocates; reply with PortBuffers". The server sets it only if our port advertised CAN_ALLOC_BUFFERS.

Layout of each buffer's region (map mem_id at offset/size):

1. The metas, back to back, each padded to 8 bytes. Meta Header (type 1) is 32 bytes: u32 flags, u32 offset, i64 pts, i64 dts_offset, u64 seq.
2. Then n_datas `spa_chunk`s of 16 bytes each: u32 offset, u32 size, i32 stride, i32 flags.
3. Then, for data_type **MemPtr (1)**, the sample memory at **`data` = a byte offset from the start of the region**, `maxsize` bytes long. For data_type **MemId (4)**, `data` is a mem_id from AddMem and the memory is at `mapoffset` within that block (the server rewrites MemFd/DmaBuf to MemId on the wire).

With no ALLOC and remote nodes, the server allocates everything in one shared memfd. It prefers MemPtr unless our Buffers `dataType` excludes it (H11 buffers.c). Expect MemPtr.

Data flags: READABLE 1, WRITABLE 2, DYNAMIC 4, MAPPABLE 8. Since 1.5.85 MemPtr datas no longer carry MAPPABLE (S5). Do not use that flag to decide anything.

Negotiation [V H11 buffers.c, impl-link.c]: the number of buffers is the smaller of what both ports allow and the server's maximum. The link always uses the async flag, so there are at least 2 buffers. Size is the larger of the requested sizes. With no Buffers param on either side, the size falls back to `clock.quantum-limit` × 1 block and 2 buffers.

---

## 6. The simplest working sequence (F32, stereo, 48 kHz, quantum 128)

Ids: Core 0, Client 1, Registry 2, ClientNode 3, Links 4 and 5. "→" means client to server; "←" means server to client. Message order on the server side is shown as observed in the code. Exact interleaving is [U]. **Answer every Core::Ping with Pong immediately, at any point.**

### 6.1 Path A: link it ourselves, independent of the session manager (recommended for bring-up)

1. Connect to `$XDG_RUNTIME_DIR/pipewire-0`.
2. → `0/Core::Hello(4)`. ← Core::Info [V H11 impl-core.c], then Client::Info on id 1 [U: expected from the bind; not traced].
3. → `1/Client::UpdateProperties({application.name=…})`. *Optional.* [V S1]
4. → `0/Core::GetRegistry(3, 2)`, then → `0/Core::Sync(0, s1)`. ← `2/Registry::Global` × N, then ← `0/Core::Done(0, s1)`.
   Pick the sink, either by `media.class=Audio/Sink` or by binding the `default` Metadata and reading `default.audio.sink` (*optional*). Record its input Port globals with `audio.channel` FL and FR.
5. → `0/Core::CreateObject("client-node", "PipeWire:Interface:ClientNode", 6, {node.name, node.description, media.type=Audio, media.category=Playback, media.role=Music, node.autoconnect=false, node.latency=128/48000, node.rate=1/48000}, 3)`.
6. → `3/ClientNode::Update(change_mask 3, 0 params, info{max_in 0, max_out 2, mask 7, flags 0, props…, 0 param-info})`.
7. → `3/ClientNode::PortUpdate(dir 1, port 0, mask 3, params [EnumFormat dsp/F32P, Buffers, IO], info{FL…})`, then the same for port 1 with FR. [§4.4]
8. ← `0/Core::Ping(3, x)` → `0/Core::Pong(3, x)`. This lets the node register. [V H11 spa-node.c]
9. ← `0/Core::BoundProps(3, NODE_ID, props)`. ← `0/Core::AddMem(m, MemFd, fd, flags)`. ← `3/ClientNode::Transport(readfd, writefd, m, off, 2312)`.
   Map the record and write client_version = 1. [V H7, H8]
   There may also be ← `SetIO(Clock)` and ← `SetActivation(NODE_ID, …)` (our own record as a temporary self-target until a driver is assigned) [V H10].
10. → `3/ClientNode::SetActive(true)`.
11. → `0/Core::Sync`, and wait for ← `2/Registry::Global` for our two Port objects (`node.id = NODE_ID`) to get their global ids.
12. → `0/Core::CreateObject("link-factory", "PipeWire:Interface:Link", 3, {link.output.node=NODE_ID, link.output.port=<our FL port global>, link.input.node=<sink id>, link.input.port=<sink FL port global>}, 4)`, and the same for FR with id 5.
    Links die with our connection unless `object.linger=true` is set. [V H11 module-link-factory.c]
13. Negotiation. For each port the order is roughly:
    - ← PortSetMixInfo(1, p, mix, peer).
    - ← PortSetParam(PeerCapability / Latency / …), which we ignore.
    - ← **PortSetParam(1, p, Format, …)**: accept it, then → **PortUpdate** with Format and Buffers (§4.3).
    - ← Ping → Pong.
    - ← AddMem + **PortUseBuffers(1, p, 0xFFFFFFFF, 0, n, …)**: map it.
    - ← Ping → Pong.
    - ← AddMem + **SetActivation(sink, fd, …)** and **SetActivation(driver, fd, …)**.
    - ← **SetIO(Position, m, off, size)**: map it and write active_driver_id.
    - ← AddMem + **PortSetIO(1, p, mix, Buffers, m, off, 8)**.
14. ← `3/ClientNode::Command(Start)`. Set status FINISHED and start polling readfd.
15. Real-time loop (§5.4–5.5): each wake-up, write `clock.duration` samples per channel and trigger the targets. **Audio plays.** [U end-to-end. Each step is [V] against code; the whole sequence has not been run]
16. Shutdown (*optional but polite*):
    - → `3/ClientNode::SetActive(false)`. ← Command(Pause or Suspend), so mark INACTIVE.
    - → `0/Core::Destroy(4)`, `Destroy(5)`, `Destroy(3)`. ← RemoveId for each.
    - Close the socket. The server cleans up everything on disconnect regardless.

### 6.2 Optional steps

Optional: UpdateProperties (3), the Metadata bind (4), GetNode, the Latency/Tag/Meta params, the AsyncBuffers IO param, `node.force-quantum`, and the shutdown sequence (16).

Mandatory:

- Hello with version ≥ 3 (send 4).
- Pong to every Ping.
- Update and PortUpdate before the Pong in step 8. The node can be updated later, but ports must exist before linking.
- client_version = 1.
- active_driver_id.
- SetActive(true).
- The PortUpdate echoing Format.
- Triggering every target every cycle.

### 6.3 Path B: let WirePlumber link it

[V W1–W3 source reading; U untested]

- Set `media.class=Stream/Output/Audio` and `node.autoconnect=true`. WirePlumber then wraps the node in an "si-audio-adapter" item (W3).
- That item **requires a node-level EnumFormat with subtype raw**, which it reads by enumerating the Node's params. Otherwise it logs "no usable format found" and never links (W1). Publish, in Update, an EnumFormat {audio, raw, F32_LE, rate 48000, channels 2, position [FL, FR]} with param-info EnumFormat READ.
- When it links to a DSP-mode sink, WirePlumber sends **ClientNode::SetParam(PortConfig { direction Output, mode dsp, monitor false, control false, format <the sink's raw format> })**. It may send Command(Suspend) first if the node is IDLE or beyond. It then waits until the node's port list changes (W1 `set_ports_format`, W2 `configure_adapter`).
- The minimal response is to start with **zero ports**. On PortConfig, create one dsp F32P output port per channel in the PortConfig format's position array, each with `audio.channel` set, and send a PortUpdate for each. WirePlumber then links ports by matching `audio.channel` (W2 `score_ports`).
- A node that already has ports can instead toggle the SERIAL bit of its Props param-info. W1 also finishes on a Props param change. [U]

---

## 7. Pitfalls, versions and what PipeWire checks strictly

### 7.1 Version history relevant to us

- **Protocol v3**: the 16-byte header with `seq` and `n_fds`. v0 had an 8-byte header and is still auto-detected (§1.2). [V H1] [U: the release that introduced v3; 0.3 era]
- 0.3.33: PortSetMixInfo (ClientNode v4). [V S5]
- 0.3.48: message footer and registry generation. [V S5]
- 0.3.68: Core::BoundProps (Core v4). [V S5]
- 0.3.72: driver activation reworked so that out-of-process drivers do not go through the server. [V S5]
- **1.2.0 (2024-06-27)**: asynchronous node scheduling, `SPA_IO_AsyncBuffers`, and a reworked activation. The header comment names this "activation version 1": status changes by compare-and-swap, `client_version`/`server_version` fields, the driver resumes async nodes, and sync groups. [V H9 comment, S5] [U: that the constant changed exactly at 1.2.0 rather than in a 1.1.x pre-release]
- 1.5.0: PeerEnumFormat. 1.5.84: Capability and PeerCapability params (which the server now sends at link time). 1.5.85: MemPtr buffer data lose the MAPPABLE flag. [V H13 comments, S5]

### 7.2 Where the documentation and the code disagree

1. **Hello version.** S1 says 3. The code sends `PW_VERSION_CORE` = 4, and the server uses ≥ 4 to choose BoundProps. [V]
2. **Transport's third argument.** S1 calls it "memfd: the index of the memfd". The code parses it as an Int **mem_id** that refers to an earlier AddMem (H6 marshal, H8 `pw_mempool_map_id`). The two Fd arguments are indexes; this one is not. [V]
3. **Header diagram.** S1 shows opcode as the leading byte of word 2. The code computes `opcode = word >> 24`, which is byte 7 in little-endian memory. [V]
4. **UseBuffers.** S1 names it "UseBuffers". It is `PORT_USE_BUFFERS`, event 8, and is per port. There is no node-level variant. [V]
5. **S1's flow** omits the AddMem that precedes SetIO/PortSetIO areas, and the Pings. The code sends both. [V]

### 7.3 Things the server checks strictly (and silent failure modes)

- Hello's header word 3 (`n_fds`) must be < 4, or the server assumes protocol v0. [V H1]
- `n_fds` beyond the fds actually received gives EPROTO and kills the connection. [V H1]
- Payloads must parse exactly as specified. Every wrong type gets Core::Error EINVAL, and the call is dropped, not the connection. [V H3, H6]
- **Unanswered Ping**: the node is never registered, or the link never completes. There is no error. [V H11 spa-node.c, impl-link.c]
- **`active_driver_id` not set**: the driver skips the node every cycle. There is no error and no sound. [V H10]
- **`client_version` left 0**: the server assumes the legacy protocol and manages our status for us, which races with our own CAS. [V H7, H10]
- Port ids must be dense; otherwise PortUpdate fails with EINVAL. [V H7]
- Params must be Object PODs (or None where allowed). [V H6]
- A Format that cannot be read back from our port breaks later re-negotiation. [V H11 impl-link.c]
- Activation-record ABI: not declared stable (S1). Check `server_version` (offset 544) at startup. Refuse to run (or fall back) if it is not 1. [U: policy recommendation]
- Interleaved stereo cannot link directly to DSP-mode sink ports, so use per-channel F32P ports (§4.4). [V: host port formats. U: we have not run the failing case]

### 7.4 What I could not verify

- Whether a node with **no `media.class`** (path A) is left entirely alone by WirePlumber and still gets a driver through manual links. The server assigns drivers to linked nodes (H10), and W3 only creates items for `Stream/*`, `Audio/*` and `Video/*` nodes, but this has not been tested.
- The exact order of negotiation events in §6.1, step 13, across both ports.
- Whether the server requires every param-info flag listed in §4.4, and whether node flags (RT) matter.
- Whether path B's PortConfig handshake behaves exactly as described against WirePlumber 0.5.18.
- The bit order of the bit-field word at offset 4. We never write it.
- Which client properties the server overrides from socket credentials.

None of this has been exercised end to end. The first implementation step should be a test against the host's PipeWire 1.6.9 with `PIPEWIRE_DEBUG=4` on the server side, to watch for "unknown resource", "invalid message" and "waiting for driver" logs.
