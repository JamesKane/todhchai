// SPDX-License-Identifier: BSD-3-Clause
//
// td_wire.h and idlc's generated echo.h, exercised from C. The Swift tests
// (tests/ipc/idl) compare these messages with the Swift codec's.

#ifndef IDL_C_TESTS_H
#define IDL_C_TESTS_H

#include <stdint.h>

// Encodes Echo.say("hi", times: 3) with txid 1; returns the byte count.
uint32_t idl_c_encode_say(uint8_t *out, uint32_t capacity);

// Decodes `bytes` as Echo.say's reply; returns 0 and the string, or a
// nonzero status.
int32_t idl_c_decode_say_reply(const uint8_t *bytes, uint32_t count, char *text, uint32_t capacity);

// td_wire_utf8_valid, for the Swift tests to compare with Swift's validation.
int idl_c_utf8_valid(const uint8_t *bytes, uint32_t count);

#endif
