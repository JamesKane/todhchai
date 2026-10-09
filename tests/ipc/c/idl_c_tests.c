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
