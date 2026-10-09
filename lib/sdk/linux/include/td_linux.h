// SPDX-License-Identifier: BSD-3-Clause
//
// Linux calls the SDK's hosted backend needs that Swift can't make
// (principle 28: calling-convention shims): prctl and syscall are variadic,
// and Glibc's Swift module hides the GNU extensions.

#ifndef TD_LINUX_H
#define TD_LINUX_H

#include <stdint.h>
// Not in Glibc's Swift module: the loop's kernel interfaces, re-exported here.
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>

// The calling thread's timer slack, in ns (at least 1).
int td_linux_set_timer_slack(uint64_t ns);
// SCHED_DEADLINE for the calling thread; 0 on success, else an errno.
int td_linux_sched_deadline(uint64_t runtime_ns, uint64_t deadline_ns, uint64_t period_ns);
// SCHED_FIFO at `priority`; 0 or an errno.
int td_linux_sched_fifo(int priority);
// SCHED_BATCH (throughput) or SCHED_IDLE (background); 0 or an errno.
int td_linux_sched_batch(void);
int td_linux_sched_idle(void);
// An anonymous file for shared memory (memfd_create, close-on-exec).
int td_linux_memfd(const char *name);
// The calling thread's name (at most 15 bytes are kept).
void td_linux_set_thread_name(const char *name);

#endif
