// SPDX-License-Identifier: BSD-3-Clause

#include "idl_c_tests.h"

#include <echo.h>
#include <stdlib.h>
#include <string.h>

uint32_t idl_c_encode_say(uint8_t *out, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  if (!m) return 0;
  uint32_t n = 0;
  if (echo_say_encode(m, 1, "hi", 2, 3) == TD_OK && m->byte_count <= capacity) {
    memcpy(out, m->bytes, m->byte_count);
    n = m->byte_count;
  }
  free(m);
  return n;
}

int32_t idl_c_decode_say_reply(const uint8_t *bytes, uint32_t count, char *text, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  if (!m || count > sizeof m->bytes) {
    free(m);
    return TD_ERR_OUT_OF_RANGE;
  }
  memcpy(m->bytes, bytes, count);
  m->byte_count = count;
  m->handle_count = 0;
  const char *result;
  uint32_t len;
  int32_t s = echo_say_decode_reply(m, &result, &len);
  if (s == TD_OK) {
    if (len + 1 > capacity) {
      s = TD_ERR_BUFFER_TOO_SMALL;
    } else {
      memcpy(text, result, len);
      text[len] = 0;
    }
  }
  free(m);
  return s;
}

int idl_c_utf8_valid(const uint8_t *bytes, uint32_t count) { return td_wire_utf8_valid(bytes, count); }

#define CHECK(cond)              \
  do {                           \
    if (!(cond)) return __LINE__; \
  } while (0)

static int echo_client(td_handle_t ch, td_wire_msg_t *buf) {
  int32_t code = 0;
  const char *text;
  uint32_t len;
  CHECK(echo_say(ch, 1, buf, &code, "hi", 2, 3, &text, &len) == TD_OK);
  CHECK(len == 6 && memcmp(text, "hihihi", 6) == 0);
  CHECK(echo_say(ch, 2, buf, &code, "long", 4, 100, &text, &len) == TD_ERR_REMOTE);
  CHECK(code == ECHO_ERROR_TOO_LONG);

  CHECK(echo_note(ch, buf, 5, false) == TD_OK);
  CHECK(echo_note(ch, buf, 5, true) == TD_OK);
  uint64_t noted = 0;
  CHECK(echo_noted(ch, 3, buf, &code, &noted) == TD_OK);
  CHECK(noted == 15);

  // The handle goes to the server and comes back: the same event, as the
  // user signal set before sending shows.
  td_handle_t event, back = TD_HANDLE_INVALID;
  CHECK(td_event_create(&event) == TD_OK);
  CHECK(td_object_signal(event, 0, 1u << 24) == TD_OK);
  CHECK(echo_swap(ch, 4, buf, &code, event, &back) == TD_OK);
  CHECK(back != TD_HANDLE_INVALID);
  CHECK(td_object_signal(event, 0, TD_EVENT_SIGNALED) == TD_ERR_BAD_HANDLE);  // it moved
  uint32_t observed = 0;
  CHECK(td_object_wait_one(back, 1u << 24, 0, &observed) == TD_OK);
  CHECK(td_handle_close(back) == TD_OK);
  return 0;
}

int idl_c_echo_client(uint32_t channel) {
  td_wire_msg_t *buf = malloc(sizeof *buf);
  if (!buf) return __LINE__;
  int result = echo_client(channel, buf);
  free(buf);
  td_handle_close(channel);
  return result;
}
