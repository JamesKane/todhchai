// SPDX-License-Identifier: BSD-3-Clause

#include "host_c_tests.h"

#include <string.h>
#include <td_kernel.h>

#define CHECK(cond)          \
  do {                       \
    if (!(cond)) return __LINE__; \
  } while (0)

int host_c_channel_round_trip(void) {
  td_handle_t a, b;
  CHECK(td_channel_create(&a, &b) == TD_OK);
  const char msg[] = "hello from C";
  CHECK(td_channel_write(a, msg, sizeof msg, NULL, 0) == TD_OK);

  uint32_t observed = 0;
  CHECK(td_object_wait_one(b, TD_CHANNEL_READABLE, TD_TIME_INFINITE, &observed) == TD_OK);
  CHECK(observed & TD_CHANNEL_READABLE);

  char got[64];
  uint32_t n = 0, nh = 0;
  CHECK(td_channel_read(b, got, sizeof got, &n, NULL, 0, &nh) == TD_OK);
  CHECK(n == sizeof msg && nh == 0 && memcmp(got, msg, n) == 0);
  CHECK(td_channel_read(b, got, sizeof got, &n, NULL, 0, &nh) == TD_ERR_SHOULD_WAIT);

  CHECK(td_handle_close(a) == TD_OK);
  CHECK(td_object_wait_one(b, TD_CHANNEL_PEER_CLOSED, 0, &observed) == TD_OK);
  CHECK(td_channel_read(b, got, sizeof got, &n, NULL, 0, &nh) == TD_ERR_PEER_CLOSED);
  CHECK(td_handle_close(b) == TD_OK);
  CHECK(td_handle_close(b) == TD_ERR_BAD_HANDLE);
  return 0;
}

int host_c_read_too_small(void) {
  td_handle_t a, b;
  CHECK(td_channel_create(&a, &b) == TD_OK);
  char big[100] = {0};
  CHECK(td_channel_write(a, big, sizeof big, NULL, 0) == TD_OK);
  char small[10];
  uint32_t n = 0, nh = 0;
  CHECK(td_channel_read(b, small, sizeof small, &n, NULL, 0, &nh) == TD_ERR_BUFFER_TOO_SMALL);
  CHECK(n == 100 && nh == 0);
  CHECK(td_channel_read(b, big, sizeof big, &n, NULL, 0, &nh) == TD_OK);  // still queued
  CHECK(n == 100);
  td_handle_close(a);
  td_handle_close(b);
  return 0;
}

int host_c_handle_moves(void) {
  td_handle_t a, b, e;
  CHECK(td_channel_create(&a, &b) == TD_OK);
  CHECK(td_event_create(&e) == TD_OK);
  CHECK(td_channel_write(a, "e", 1, &e, 1) == TD_OK);
  CHECK(td_object_signal(e, 0, TD_EVENT_SIGNALED) == TD_ERR_BAD_HANDLE);  // moved

  char got[8];
  td_handle_t moved = TD_HANDLE_INVALID;
  uint32_t n = 0, nh = 0;
  CHECK(td_channel_read(b, got, sizeof got, &n, &moved, 1, &nh) == TD_OK);
  CHECK(nh == 1 && moved != TD_HANDLE_INVALID);
  CHECK(td_object_signal(moved, 0, TD_EVENT_SIGNALED) == TD_OK);
  uint32_t observed = 0;
  CHECK(td_object_wait_one(moved, TD_EVENT_SIGNALED, 0, &observed) == TD_OK);

  // A channel can't carry itself, and the handle is consumed anyway.
  CHECK(td_channel_write(a, "x", 1, &a, 1) == TD_ERR_NOT_SUPPORTED);
  CHECK(td_handle_close(a) == TD_ERR_BAD_HANDLE);
  td_handle_close(b);
  td_handle_close(moved);
  return 0;
}
