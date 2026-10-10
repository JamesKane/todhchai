// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and the system call (see
// amd64.S for why these are assembly).

.section .text._start, "ax"
.globl _start
_start:
  mov x29, #0
  mov x30, #0
  bl td_start
  brk #0

// td_syscall6(number, a0..a5): croi's convention is svc #0 with the number
// in x16 and arguments in x0-x5.
.section .text.td_syscall6, "ax"
.globl td_syscall6
td_syscall6:
  mov x16, x0
  mov x0, x1
  mov x1, x2
  mov x2, x3
  mov x3, x4
  mov x4, x5
  mov x5, x6
  svc #0
  ret

.section .data.__stack_chk_guard, "aw"
.globl __stack_chk_guard
.balign 8
__stack_chk_guard:
  .quad 0x595e9fbd94fda766
