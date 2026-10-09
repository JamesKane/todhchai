// SPDX-License-Identifier: BSD-3-Clause

#define _GNU_SOURCE
#include "td_linux.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int td_linux_set_timer_slack(uint64_t ns) {
  return prctl(PR_SET_TIMERSLACK, (unsigned long)(ns ? ns : 1), 0, 0, 0) == 0 ? 0 : errno;
}

// struct sched_attr (the kernel's; glibc has no wrapper for sched_setattr).
struct td_sched_attr {
  uint32_t size, policy;
  uint64_t flags;
  int32_t nice;
  uint32_t priority;
  uint64_t runtime, deadline, period;
};

int td_linux_sched_deadline(uint64_t runtime_ns, uint64_t deadline_ns, uint64_t period_ns) {
  struct td_sched_attr attr = {
      .size = sizeof attr, .policy = 6 /* SCHED_DEADLINE */,
      .runtime = runtime_ns, .deadline = deadline_ns, .period = period_ns,
  };
  return syscall(SYS_sched_setattr, 0, &attr, 0) == 0 ? 0 : errno;
}

static int set_policy(int policy, int priority) {
  struct sched_param param = {.sched_priority = priority};
  return pthread_setschedparam(pthread_self(), policy, &param);
}

int td_linux_sched_fifo(int priority) { return set_policy(SCHED_FIFO, priority); }
int td_linux_sched_batch(void) { return set_policy(SCHED_BATCH, 0); }
int td_linux_sched_idle(void) { return set_policy(SCHED_IDLE, 0); }

void td_linux_set_thread_name(const char *name) {
  char short_name[16];
  strncpy(short_name, name, 15);
  short_name[15] = 0;
  pthread_setname_np(pthread_self(), short_name);
}
