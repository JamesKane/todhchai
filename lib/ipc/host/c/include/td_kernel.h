// SPDX-License-Identifier: BSD-3-Clause
//
// Handles, channels, events and waiting: the calls croi will provide, as
// the hosted kernel (lib/ipc/host) provides them in M0. Semantics follow
// Zircon's: a write consumes its handles even when it fails; deadlines are
// absolute, in nanoseconds on the monotonic clock.

#ifndef TD_KERNEL_H
#define TD_KERNEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t td_handle_t;
typedef int32_t td_status_t;
typedef int64_t td_time_t;

#define TD_HANDLE_INVALID ((td_handle_t)0)
#define TD_TIME_INFINITE INT64_MAX

#define TD_OK 0
#define TD_ERR_NOT_SUPPORTED (-2)
#define TD_ERR_INVALID_ARGS (-10)
#define TD_ERR_BAD_HANDLE (-11)
#define TD_ERR_WRONG_TYPE (-12)
#define TD_ERR_OUT_OF_RANGE (-14)
#define TD_ERR_BUFFER_TOO_SMALL (-15)
#define TD_ERR_TIMED_OUT (-21)
#define TD_ERR_SHOULD_WAIT (-22)
#define TD_ERR_CANCELED (-23)
#define TD_ERR_PEER_CLOSED (-24)
#define TD_ERR_ACCESS_DENIED (-30)

#define TD_CHANNEL_READABLE (1u << 0)
#define TD_CHANNEL_PEER_CLOSED (1u << 2)
#define TD_EVENT_SIGNALED (1u << 3)
#define TD_USER_SIGNALS 0xff000000u

#define TD_CHANNEL_MAX_MSG_BYTES 65536u
#define TD_CHANNEL_MAX_MSG_HANDLES 64u

td_status_t td_handle_close(td_handle_t handle);

td_status_t td_channel_create(td_handle_t *out0, td_handle_t *out1);
td_status_t td_channel_write(td_handle_t channel, const void *bytes, uint32_t byte_count,
                             const td_handle_t *handles, uint32_t handle_count);
// On TD_ERR_BUFFER_TOO_SMALL the message stays queued, and *actual_bytes and
// *actual_handles say what it needs.
td_status_t td_channel_read(td_handle_t channel, void *bytes, uint32_t byte_capacity,
                            uint32_t *actual_bytes, td_handle_t *handles, uint32_t handle_capacity,
                            uint32_t *actual_handles);

td_status_t td_event_create(td_handle_t *out);
td_status_t td_object_signal(td_handle_t handle, uint32_t clear, uint32_t set);
td_status_t td_object_wait_one(td_handle_t handle, uint32_t signals, td_time_t deadline,
                               uint32_t *observed);

td_time_t td_clock_monotonic(void);

#ifdef __cplusplus
}
#endif

#endif
