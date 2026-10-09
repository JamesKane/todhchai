// SPDX-License-Identifier: BSD-3-Clause
//
// The IPC wire format (docs/wire-format.md) in C: message encoding and
// decoding, and a call helper over td_kernel.h. Headers that idlc generates
// for each protocol are built on this one. Everything is static inline, so
// a C program needs only these headers and the kernel calls.
//
// Written from docs/wire-format.md, like lib/ipc/wire (IPCWire), and kept
// byte-for-byte compatible with it by tests/ipc/c.

#ifndef TD_WIRE_H
#define TD_WIRE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <td_kernel.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TD_WIRE_VERSION 1u
#define TD_WIRE_HEADER_SIZE 16u
#define TD_WIRE_ERROR_INLINE_SIZE 8u

// Message kinds.
#define TD_WIRE_REQUEST 1u
#define TD_WIRE_REPLY 2u
#define TD_WIRE_EVENT 3u
#define TD_WIRE_CANCEL 4u
#define TD_WIRE_EPITAPH 5u

// Header flags (replies only).
#define TD_WIRE_FLAG_CANCELED (1u << 0)
#define TD_WIRE_FLAG_ERROR (1u << 1)
#define TD_WIRE_FLAGS_KNOWN (TD_WIRE_FLAG_CANCELED | TD_WIRE_FLAG_ERROR)

// Statuses beyond the kernel's: the peer broke the protocol, or the method
// failed with its own error (whose code is returned separately).
#define TD_ERR_PROTOCOL (-50)
#define TD_ERR_REMOTE (-51)

// A message: its bytes and handles. 64 KiB, so callers usually keep one
// rather than putting it on a small stack.
typedef struct td_wire_msg {
  _Alignas(8) uint8_t bytes[TD_CHANNEL_MAX_MSG_BYTES];
  uint32_t byte_count;
  td_handle_t handles[TD_CHANNEL_MAX_MSG_HANDLES];
  uint32_t handle_count;
} td_wire_msg_t;

typedef struct td_wire_header {
  uint32_t txid;
  uint8_t kind;
  uint16_t flags;
  uint64_t ordinal;
} td_wire_header_t;

// Little-endian access, whatever the host's byte order.
static inline void td_wire_put(uint8_t *p, uint64_t v, unsigned size) {
  for (unsigned i = 0; i < size; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static inline uint64_t td_wire_get(const uint8_t *p, unsigned size) {
  uint64_t v = 0;
  for (unsigned i = 0; i < size; i++) v |= (uint64_t)p[i] << (8 * i);
  return v;
}
static inline uint32_t td_wire_aligned(uint32_t n) { return (n + 7u) & ~7u; }

// ---- Encoding ------------------------------------------------------------

// Writes the header and reserves a zeroed inline part of inline_size bytes
// (rounded up to 8). Stores then go at offsets within the inline part.
static inline td_status_t td_wire_begin(td_wire_msg_t *m, uint32_t txid, uint8_t kind, uint16_t flags,
                                        uint64_t ordinal, uint32_t inline_size) {
  uint32_t size = TD_WIRE_HEADER_SIZE + td_wire_aligned(inline_size);
  if (size > sizeof m->bytes) return TD_ERR_OUT_OF_RANGE;
  memset(m->bytes, 0, size);
  td_wire_put(m->bytes + 0, txid, 4);
  m->bytes[4] = kind;
  m->bytes[5] = TD_WIRE_VERSION;
  td_wire_put(m->bytes + 6, flags, 2);
  td_wire_put(m->bytes + 8, ordinal, 8);
  m->byte_count = size;
  m->handle_count = 0;
  return TD_OK;
}

// An integer of `size` bytes at inline offset `offset`.
static inline void td_wire_store(td_wire_msg_t *m, uint32_t offset, uint64_t v, unsigned size) {
  td_wire_put(m->bytes + TD_WIRE_HEADER_SIZE + offset, v, size);
}

// A byte string: count and presence inline, the bytes out of line.
static inline td_status_t td_wire_store_bytes(td_wire_msg_t *m, uint32_t offset, const void *data,
                                              uint32_t count) {
  uint32_t padded = td_wire_aligned(count);
  if (count > sizeof m->bytes || m->byte_count + padded > sizeof m->bytes) return TD_ERR_OUT_OF_RANGE;
  td_wire_store(m, offset, count, 8);
  td_wire_store(m, offset + 8, UINT64_MAX, 8);
  memset(m->bytes + m->byte_count, 0, padded);
  if (count) memcpy(m->bytes + m->byte_count, data, count);
  m->byte_count += padded;
  return TD_OK;
}

// A handle, moved into the message (or absent, as TD_HANDLE_INVALID).
static inline td_status_t td_wire_store_handle(td_wire_msg_t *m, uint32_t offset, td_handle_t h) {
  if (h == TD_HANDLE_INVALID) {
    td_wire_store(m, offset, 0, 4);
    return TD_OK;
  }
  if (m->handle_count >= TD_CHANNEL_MAX_MSG_HANDLES) return TD_ERR_OUT_OF_RANGE;
  td_wire_store(m, offset, UINT32_MAX, 4);
  m->handles[m->handle_count++] = h;
  return TD_OK;
}

// ---- Decoding ------------------------------------------------------------
// Messages are untrusted: every read is checked, padding must be zero, and
// everything must be consumed. Failures return TD_ERR_PROTOCOL.

typedef struct td_wire_reader {
  const td_wire_msg_t *m;
  uint32_t inline_size;
  uint32_t next;         // the next out-of-line byte
  uint32_t next_handle;  // the next handle in the side array
} td_wire_reader_t;

static inline td_status_t td_wire_header(const td_wire_msg_t *m, td_wire_header_t *h) {
  if (m->byte_count < TD_WIRE_HEADER_SIZE || m->byte_count % 8 || m->byte_count > sizeof m->bytes)
    return TD_ERR_PROTOCOL;
  if (m->bytes[5] != TD_WIRE_VERSION || m->bytes[4] < TD_WIRE_REQUEST || m->bytes[4] > TD_WIRE_EPITAPH)
    return TD_ERR_PROTOCOL;
  h->txid = (uint32_t)td_wire_get(m->bytes, 4);
  h->kind = m->bytes[4];
  h->flags = (uint16_t)td_wire_get(m->bytes + 6, 2);
  h->ordinal = td_wire_get(m->bytes + 8, 8);
  return (h->flags & ~TD_WIRE_FLAGS_KNOWN) ? TD_ERR_PROTOCOL : TD_OK;
}

static inline td_status_t td_wire_read_begin(td_wire_reader_t *r, const td_wire_msg_t *m, uint32_t inline_size) {
  td_wire_header_t h;
  if (td_wire_header(m, &h) != TD_OK) return TD_ERR_PROTOCOL;
  r->m = m;
  r->inline_size = td_wire_aligned(inline_size);
  r->next = TD_WIRE_HEADER_SIZE + r->inline_size;
  r->next_handle = 0;
  return r->next <= m->byte_count ? TD_OK : TD_ERR_PROTOCOL;
}

static inline td_status_t td_wire_load(const td_wire_reader_t *r, uint32_t offset, unsigned size, uint64_t *v) {
  if (offset + size > r->inline_size) return TD_ERR_PROTOCOL;
  *v = td_wire_get(r->m->bytes + TD_WIRE_HEADER_SIZE + offset, size);
  return TD_OK;
}

static inline td_status_t td_wire_check_padding(const td_wire_reader_t *r, uint32_t offset, uint32_t count) {
  if (offset + count > r->inline_size) return TD_ERR_PROTOCOL;
  for (uint32_t i = 0; i < count; i++)
    if (r->m->bytes[TD_WIRE_HEADER_SIZE + offset + i]) return TD_ERR_PROTOCOL;
  return TD_OK;
}

static inline td_status_t td_wire_load_bool(const td_wire_reader_t *r, uint32_t offset, uint8_t *v) {
  uint64_t raw;
  if (td_wire_load(r, offset, 1, &raw) != TD_OK || raw > 1) return TD_ERR_PROTOCOL;
  *v = (uint8_t)raw;
  return TD_OK;
}

// A byte string, as a pointer into the message (no copy).
static inline td_status_t td_wire_load_bytes(td_wire_reader_t *r, uint32_t offset, const uint8_t **data,
                                             uint32_t *count) {
  uint64_t n, presence;
  if (td_wire_load(r, offset, 8, &n) || td_wire_load(r, offset + 8, 8, &presence)) return TD_ERR_PROTOCOL;
  if (presence != UINT64_MAX || n > r->m->byte_count - r->next) return TD_ERR_PROTOCOL;
  uint32_t padded = td_wire_aligned((uint32_t)n);
  if (r->next + padded > r->m->byte_count) return TD_ERR_PROTOCOL;
  for (uint32_t i = (uint32_t)n; i < padded; i++)
    if (r->m->bytes[r->next + i]) return TD_ERR_PROTOCOL;
  *data = r->m->bytes + r->next;
  *count = (uint32_t)n;
  r->next += padded;
  return TD_OK;
}

// Whether data[0..count) is valid UTF-8 (Unicode §3.9, table 3-7): no
// overlong forms, no surrogates, nothing above U+10FFFF.
static inline int td_wire_utf8_valid(const uint8_t *s, uint32_t count) {
  uint32_t i = 0;
  while (i < count) {
    uint8_t c = s[i];
    uint32_t need;
    uint8_t lo = 0x80, hi = 0xbf;
    if (c < 0x80) { i++; continue; }
    else if (c >= 0xc2 && c <= 0xdf) need = 1;
    else if (c == 0xe0) { need = 2; lo = 0xa0; }
    else if (c >= 0xe1 && c <= 0xec) need = 2;
    else if (c == 0xed) { need = 2; hi = 0x9f; }
    else if (c >= 0xee && c <= 0xef) need = 2;
    else if (c == 0xf0) { need = 3; lo = 0x90; }
    else if (c >= 0xf1 && c <= 0xf3) need = 3;
    else if (c == 0xf4) { need = 3; hi = 0x8f; }
    else return 0;
    if (count - i <= need) return 0;
    if (s[i + 1] < lo || s[i + 1] > hi) return 0;
    for (uint32_t k = 2; k <= need; k++)
      if (s[i + k] < 0x80 || s[i + k] > 0xbf) return 0;
    i += need + 1;
  }
  return 1;
}

// A string: a byte string that must be valid UTF-8. Not NUL-terminated.
static inline td_status_t td_wire_load_string(td_wire_reader_t *r, uint32_t offset, const char **text,
                                              uint32_t *len) {
  const uint8_t *data;
  if (td_wire_load_bytes(r, offset, &data, len) != TD_OK || !td_wire_utf8_valid(data, *len))
    return TD_ERR_PROTOCOL;
  *text = (const char *)data;
  return TD_OK;
}

// A handle that must be present. It becomes the caller's.
static inline td_status_t td_wire_load_handle(td_wire_reader_t *r, uint32_t offset, td_handle_t *h) {
  uint64_t marker;
  if (td_wire_load(r, offset, 4, &marker) != TD_OK || marker != UINT32_MAX) return TD_ERR_PROTOCOL;
  if (r->next_handle >= r->m->handle_count) return TD_ERR_PROTOCOL;
  *h = r->m->handles[r->next_handle++];
  return TD_OK;
}

// Every byte and handle must have been consumed.
static inline td_status_t td_wire_read_end(const td_wire_reader_t *r) {
  return r->next == r->m->byte_count && r->next_handle == r->m->handle_count ? TD_OK : TD_ERR_PROTOCOL;
}

// Closes every handle a message carries: for a message that is dropped.
static inline void td_wire_close_handles(const td_wire_msg_t *m) {
  for (uint32_t i = 0; i < m->handle_count; i++) td_handle_close(m->handles[i]);
}

// ---- Calls ---------------------------------------------------------------

// Sends `request` (whose handles move) and waits for the reply with
// transaction id `txid`, into `reply`. Events that arrive first are
// dropped, closing their handles; a C client that wants events reads the
// channel itself. An error reply returns TD_ERR_REMOTE with *error_code set
// (positive: the method's own; negative: a framework status).
static inline td_status_t td_wire_call(td_handle_t channel, td_wire_msg_t *request, uint32_t txid,
                                       td_wire_msg_t *reply, int32_t *error_code) {
  td_status_t s = td_channel_write(channel, request->bytes, request->byte_count, request->handles,
                                   request->handle_count);
  if (s != TD_OK) return s;
  for (;;) {
    s = td_channel_read(channel, reply->bytes, sizeof reply->bytes, &reply->byte_count, reply->handles,
                        TD_CHANNEL_MAX_MSG_HANDLES, &reply->handle_count);
    if (s == TD_ERR_SHOULD_WAIT) {
      uint32_t observed;
      s = td_object_wait_one(channel, TD_CHANNEL_READABLE | TD_CHANNEL_PEER_CLOSED, TD_TIME_INFINITE,
                             &observed);
      if (s != TD_OK) return s;
      continue;
    }
    if (s != TD_OK) return s;
    td_wire_header_t h;
    if (td_wire_header(reply, &h) != TD_OK) {
      td_wire_close_handles(reply);
      return TD_ERR_PROTOCOL;
    }
    if (h.kind == TD_WIRE_EVENT) {
      td_wire_close_handles(reply);
      continue;
    }
    if (h.kind == TD_WIRE_EPITAPH) {
      td_wire_reader_t r;
      uint64_t status;
      if (td_wire_read_begin(&r, reply, TD_WIRE_ERROR_INLINE_SIZE) || td_wire_load(&r, 0, 4, &status))
        return TD_ERR_PEER_CLOSED;
      return (td_status_t)(int32_t)(uint32_t)status;
    }
    if (h.kind != TD_WIRE_REPLY || h.txid != txid) {
      td_wire_close_handles(reply);
      return TD_ERR_PROTOCOL;
    }
    if (h.flags & TD_WIRE_FLAG_CANCELED) return TD_ERR_CANCELED;
    if (h.flags & TD_WIRE_FLAG_ERROR) {
      td_wire_reader_t r;
      uint64_t code;
      if (td_wire_read_begin(&r, reply, TD_WIRE_ERROR_INLINE_SIZE) || td_wire_load(&r, 0, 4, &code) ||
          td_wire_check_padding(&r, 4, 4) || td_wire_read_end(&r))
        return TD_ERR_PROTOCOL;
      *error_code = (int32_t)(uint32_t)code;
      return TD_ERR_REMOTE;
    }
    return TD_OK;
  }
}

#ifdef __cplusplus
}
#endif

#endif
