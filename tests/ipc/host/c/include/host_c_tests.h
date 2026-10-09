// SPDX-License-Identifier: BSD-3-Clause
//
// The hosted kernel's C ABI, exercised from C. Each returns 0 on success,
// or the line number of the first failed check.

#ifndef HOST_C_TESTS_H
#define HOST_C_TESTS_H

int host_c_channel_round_trip(void);
int host_c_read_too_small(void);
int host_c_handle_moves(void);

#endif
