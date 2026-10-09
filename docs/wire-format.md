# The IPC wire format, version 1

This is the contract between every client and server, in any language.
`lib/ipc/wire` (`IPCWire`) implements it in Swift, and the C encoders that
`idlc` emits implement it in C. Neither is the definition: this file is.
The rules follow FIDL's wire format (studied, not copied; principle 29),
with the differences listed at the end.

## Messages

A message is a byte array of at most 65,536 bytes plus a side array of at
most 64 handles. Its length is a multiple of 8. All integers are
little-endian.

### Header (16 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Transaction id |
| 4 | 1 | Kind |
| 5 | 1 | Wire version: 1 |
| 6 | 2 | Flags |
| 8 | 8 | Method ordinal |

| Kind | Value | Transaction id | Body |
|---|---|---|---|
| request | 1 | nonzero for a call; 0 for a one-way request | the method's arguments |
| reply | 2 | the request's | the method's result, or none if `canceled` |
| event | 3 | 0 | the event's arguments |
| cancel | 4 | the request to cancel | none |
| epitaph | 5 | 0 | the closing status |

- **Flags.** Bit 0, `canceled`, is defined on replies only. Every other
  bit must be zero.
- **Unknown values.** A receiver rejects a message whose version, kind or
  flags it does not know.

### Ordinals

A method's ordinal is the 64-bit FNV-1a hash of `"<protocol id>.<method
name>"` in UTF-8, with bit 63 cleared:
- FNV offset basis 0xcbf29ce484222325;
- FNV prime 0x100000001b3.

Ordinals with bit 63 set are reserved for the system. The `@IPCProtocol`
macro and `idlc` reject a protocol in which two methods' ordinals collide.

### Cancellation

A client may send `cancel` for any call it has in flight. The server then
sends exactly one of these:
- the call's normal reply;
- a reply with `canceled` set and no body.

It never sends both, and never neither (9P's `Tflush` rule). A client that
receives a normal reply after cancelling uses it.

### Epitaph

An epitaph is the last message before a channel closes. Its body is a
4-byte signed status and 4 bytes of zero padding.

## Bodies

A body is an **inline part** followed by **out-of-line data**.

- **The inline part** has a fixed size that the method's signature
  determines, rounded up to a multiple of 8. Each field is at an offset
  generated code knows, naturally aligned (a 4-byte integer at a multiple
  of 4).
- **Out-of-line data** is appended after the inline part, in the order the
  fields that refer to it are encoded (depth-first). Each object starts on
  an 8-byte boundary.
- **Padding.** Every padding byte, inline or out of line, is zero.
  Receivers check this.

| Type | Inline | Out of line |
|---|---|---|
| Integers, `Bool` (1 byte, 0 or 1) | the value | — |
| Byte string, `String` (UTF-8) | 16 bytes: the count (u64), then the presence marker (u64, all ones) | the bytes, padded to 8 |
| Handle | 4 bytes: 0 if absent, all ones if present | the handle, next in the side array |

Handles appear in the side array in the order their markers are encoded.
A receiver rejects a message that leaves bytes or handles unconsumed.

Structs, tables, unions, vectors of non-byte elements and optional types
are defined with the `@IPCProtocol` macro (M0d), and this file grows with
them.

## Differences from FIDL

- **The header.** It has a kind byte, with cancel and epitaph as kinds.
  FIDL has no cancel, and marks epitaphs with a reserved ordinal.
- **Ordinals use FNV-1a instead of SHA-256.** Ordinals are computed at
  build time by our own tools, and FNV-1a needs no cryptography code before
  the crypto foundation exists. Collisions within a protocol fail the
  build. Across protocols they don't matter, because a channel speaks one
  protocol.
- **Handles carry no rights or types on the wire.** The transport checks
  them (M0c).
