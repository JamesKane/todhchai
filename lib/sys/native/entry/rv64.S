// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and the system call (see
// amd64.S for why these are assembly).

.section .text._start, "ax"
.globl _start
.weak __global_pointer$
_start:
.option push
.option norelax
  lla gp, __global_pointer$
.option pop
  li fp, 0
  li ra, 0
  call td_start
  unimp

// td_syscall6(number, a0..a5): croi's convention is ecall with the number
// in a7 and arguments in a0-a5.
.section .text.td_syscall6, "ax"
.globl td_syscall6
td_syscall6:
  mv a7, a0
  mv a0, a1
  mv a1, a2
  mv a2, a3
  mv a3, a4
  mv a4, a5
  mv a5, a6
  ecall
  ret

// td_thread_block() and td_set_thread_pointer(block): tp, which croi keeps
// per thread (and nothing else here uses: no ELF TLS).
.section .text.td_thread_block, "ax"
.globl td_thread_block
td_thread_block:
  mv a0, tp
  ret

.section .text.td_set_thread_pointer, "ax"
.globl td_set_thread_pointer
td_set_thread_pointer:
  mv tp, a0
  ret

.section .sdata.__stack_chk_guard, "aw"
.globl __stack_chk_guard
.balign 8
__stack_chk_guard:
  .quad 0x595e9fbd94fda766
