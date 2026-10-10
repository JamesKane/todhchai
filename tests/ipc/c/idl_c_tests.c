// SPDX-License-Identifier: BSD-3-Clause

#include "idl_c_tests.h"

#include <test_ipc.h>
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

static const td_wire_str_t tags[] = {{"a", 1}, {"", 0}, {"ccc", 3}};
static const test_ipc_point_t path[] = {{1, 2}, {INT32_MIN, INT32_MAX}};
static const uint8_t data[] = {0, 255, 7};
static const td_wire_str_t label = {"tri", 3};
static const uint16_t weight = 513;

// The Shaped the Swift tests call `sample`.
static test_ipc_shaped_t sample(void) {
  test_ipc_shaped_t s = {
      .shape = TEST_IPC_SHAPE_TRIANGLE,
      .at = {-3, 4},
      .label = &label,
      .tags = {tags, 3},
      .path = {path, 2},
      .weight = &weight,
      .data = {data, 3},
      .flag = true,
  };
  return s;
}

uint32_t idl_c_encode_reflect(uint8_t *out, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  uint32_t n = 0;
  test_ipc_shaped_t s = sample();
  if (echo_reflect_encode(m, 1, &s) == TD_OK && m->byte_count <= capacity) {
    memcpy(out, m->bytes, m->byte_count);
    n = m->byte_count;
  }
  free(m);
  return n;
}

int32_t idl_c_decode_reflect_reply(const uint8_t *bytes, uint32_t count) {
  static td_wire_msg_t m;
  static uint8_t memory[65536];
  td_wire_arena_t arena = {memory, sizeof memory, 0};
  test_ipc_shaped_t out;
  if (count > sizeof m.bytes) return TD_ERR_OUT_OF_RANGE;
  memcpy(m.bytes, bytes, count);
  m.byte_count = count;
  m.handle_count = 0;
  return echo_reflect_decode_reply(&m, &arena, &out);
}

static int same_str(td_wire_str_t a, td_wire_str_t b) { return a.len == b.len && memcmp(a.data, b.data, a.len) == 0; }

// Whether `got` is `sample()`, field by field.
static int is_sample(const test_ipc_shaped_t *got) {
  test_ipc_shaped_t want = sample();
  CHECK(got->shape == want.shape && got->at.x == -3 && got->at.y == 4 && got->flag);
  CHECK(got->label && same_str(*got->label, label));
  CHECK(got->tags.count == 3);
  for (uint32_t i = 0; i < 3; i++) CHECK(same_str(got->tags.items[i], tags[i]));
  CHECK(got->path.count == 2 && got->path.items[1].x == INT32_MIN && got->path.items[1].y == INT32_MAX);
  CHECK(got->weight && *got->weight == 513);
  CHECK(got->data.len == 3 && memcmp(got->data.data, data, 3) == 0);
  return 0;
}

static int typed_calls(td_handle_t ch, td_wire_msg_t *buf) {
  int32_t code = 0;
  static uint8_t memory[16384];
  td_wire_arena_t arena = {memory, sizeof memory, 0};

  test_ipc_shaped_t in = sample(), out;
  CHECK(echo_reflect(ch, 10, buf, &code, &in, &arena, &out) == TD_OK);
  CHECK(is_sample(&out) == 0);
  // Too little arena for the reply's vectors: the decode says so.
  td_wire_arena_t tiny = {memory, 8, 0};
  CHECK(echo_reflect(ch, 11, buf, &code, &in, &tiny, &out) == TD_ERR_BUFFER_TOO_SMALL);

  // many: the shapes back, one per nested list (its sum as the weight),
  // and one for `maybe`.
  arena.used = 0;
  const uint32_t l0[] = {1, 2, 3}, l2[] = {10};
  const test_ipc_vec_uint32_t lists[] = {{l0, 3}, {NULL, 0}, {l2, 1}};
  test_ipc_vec_shaped_t shapes = {&in, 1}, many;
  test_ipc_vec_point_t maybe = {path, 1};
  CHECK(echo_many(ch, 12, buf, &code, shapes, (test_ipc_vec_vec_uint32_t){lists, 3}, &maybe, &arena, &many) == TD_OK);
  CHECK(many.count == 5 && is_sample(&many.items[0]) == 0);
  CHECK(*many.items[1].weight == 6 && *many.items[2].weight == 0 && *many.items[3].weight == 10);
  CHECK(many.items[4].shape == TEST_IPC_SHAPE_TRIANGLE && many.items[4].path.count == 1 && !many.items[4].weight);
  CHECK(echo_many(ch, 13, buf, &code, (test_ipc_vec_shaped_t){NULL, 0}, (test_ipc_vec_vec_uint32_t){NULL, 0}, NULL,
                  &arena, &many) == TD_OK);
  CHECK(many.count == 0);

  // optionals: the handle comes back only if everything else was present.
  td_handle_t event, back = TD_HANDLE_INVALID;
  CHECK(td_event_create(&event) == TD_OK);
  td_wire_str_t text = {"t", 1};
  td_wire_bytes_t none = {NULL, 0};
  test_ipc_point_t point = {1, 1};
  CHECK(echo_optionals(ch, 14, buf, &code, &text, &none, &point, event, &back) == TD_OK);
  CHECK(back != TD_HANDLE_INVALID && td_handle_close(back) == TD_OK);
  CHECK(echo_optionals(ch, 15, buf, &code, NULL, &none, NULL, TD_HANDLE_INVALID, &back) == TD_OK);
  CHECK(back == TD_HANDLE_INVALID);

  // carry: a struct with two handles, which come back swapped.
  td_handle_t a, b;
  CHECK(td_event_create(&a) == TD_OK && td_event_create(&b) == TD_OK);
  CHECK(td_object_signal(a, 0, 1u << 24) == TD_OK && td_object_signal(b, 0, 1u << 25) == TD_OK);
  test_ipc_carried_t carried = {{"box", 3}, a, b, &in}, got;
  arena.used = 0;
  CHECK(echo_carry(ch, 16, buf, &code, &carried, &arena, &got) == TD_OK);
  CHECK(got.name.len == 4 && memcmp(got.name.data, "box!", 4) == 0 && got.inner && is_sample(got.inner) == 0);
  uint32_t observed = 0;
  CHECK(td_object_wait_one(got.handle, 1u << 25, 0, &observed) == TD_OK);
  CHECK(td_object_wait_one(got.spare, 1u << 24, 0, &observed) == TD_OK);
  CHECK(td_handle_close(got.handle) == TD_OK && td_handle_close(got.spare) == TD_OK);
  return 0;
}

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
  return typed_calls(ch, buf);
}

int idl_c_echo_client(uint32_t channel) {
  td_wire_msg_t *buf = malloc(sizeof *buf);
  if (!buf) return __LINE__;
  int result = echo_client(channel, buf);
  free(buf);
  td_handle_close(channel);
  return result;
}
