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

// Sequentially consistent atomics on memory shared with another process
// (PipeWire's activation records), where Swift's Atomic can't live.
static inline int td_atomic_cas_u32(void *p, uint32_t expected, uint32_t desired) {
  return __atomic_compare_exchange_n((uint32_t *)p, &expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
static inline uint32_t td_atomic_xchg_u32(void *p, uint32_t v) {
  return __atomic_exchange_n((uint32_t *)p, v, __ATOMIC_SEQ_CST);
}
static inline int32_t td_atomic_sub_fetch_i32(void *p, int32_t v) {
  return __atomic_sub_fetch((int32_t *)p, v, __ATOMIC_SEQ_CST);
}
static inline uint32_t td_atomic_load_u32(const void *p) { return __atomic_load_n((const uint32_t *)p, __ATOMIC_SEQ_CST); }
static inline void td_atomic_store_u32(void *p, uint32_t v) { __atomic_store_n((uint32_t *)p, v, __ATOMIC_SEQ_CST); }
static inline void td_atomic_store_i32(void *p, int32_t v) { __atomic_store_n((int32_t *)p, v, __ATOMIC_SEQ_CST); }

// Swift's own costs (docs/performance.md, "Swift costs"), counted per
// thread through the hooks the Swift runtime offers instrumentation:
// retains and releases (an _n call counts n) and object allocations
// (class instances and array, string and closure storage; not malloc).
typedef struct td_swift_costs {
  uint64_t retains;
  uint64_t releases;
  uint64_t allocations;
} td_swift_costs;
// Starts counting, process-wide; 0, or -1 if the runtime lacks the hooks.
// Call before other threads start.
int td_swift_costs_install(void);
// The calling thread's totals since it started.
td_swift_costs td_swift_costs_read(void);

// Receives one file descriptor passed over a Unix socket (SCM_RIGHTS), as
// fusermount3 passes /dev/fuse; -1 and errno if none came. CMSG_* are
// macros Swift can't use.
int td_linux_receive_fd(int socket);

#endif
