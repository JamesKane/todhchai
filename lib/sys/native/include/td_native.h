// SPDX-License-Identifier: BSD-3-Clause

// What Swift reaches in the native runtime's assembly (entry/<arch>.S):
// the system call instruction, which Swift can't emit. Arguments and
// result are croi's (../croi/user/include/croi/syscall.h).

#pragma once
#include <stdint.h>

int64_t td_syscall6(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4,
                    uint64_t a5);

// The calling thread's block (ThreadBlock in Thread.swift), through the
// thread pointer (FS, TPIDR_EL0, tp); setting it (not amd64's: croi sets
// FS's base for a system call).
void *td_thread_block(void);
void td_set_thread_pointer(void *block);

// The program's own entry: Swift's @main emits it.
int main(int argc, char **argv);
