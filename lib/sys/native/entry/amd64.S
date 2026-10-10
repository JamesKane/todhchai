// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and the system call. Assembly
// because nothing else can be: _start is entered with no frame to return
// to (and amd64 C code expects to have been called), and Swift can't emit
// `syscall`.

// _start(bootstrap channel, arg2, vDSO base): croi's first-thread registers.
.section .text._start, "ax"
.globl _start
_start:
  xor %ebp, %ebp
  call td_start
  ud2

// td_syscall6(number, a0..a5): croi's convention is the number in rax and
// arguments in rdi rsi rdx r10 r8 r9.
.section .text.td_syscall6, "ax"
.globl td_syscall6
td_syscall6:
  mov %rdi, %rax
  mov %rsi, %rdi
  mov %rdx, %rsi
  mov %rcx, %rdx
  mov %r8, %r10
  mov %r9, %r8
  mov 8(%rsp), %r9
  syscall
  ret

// td_thread_block(): the calling thread's block (ThreadBlock, Thread.swift),
// whose first word points to itself: FS's base is set to it
// (object_set_property, CROI_PROP_REGISTER_FS), and %fs:0 reads it back.
.section .text.td_thread_block, "ax"
.globl td_thread_block
td_thread_block:
  mov %fs:0, %rax
  ret

// td_set_thread_pointer(block): amd64 sets FS's base through croi
// (ThreadBlock.install), so this is unused here.
.section .text.td_set_thread_pointer, "ax"
.globl td_set_thread_pointer
td_set_thread_pointer:
  ud2

// The stack protector's canary: fixed until croi has a random source to
// draw one from at start.
.section .data.__stack_chk_guard, "aw"
.globl __stack_chk_guard
.balign 8
__stack_chk_guard:
  .quad 0x595e9fbd94fda766
