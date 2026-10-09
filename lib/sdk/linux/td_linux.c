// SPDX-License-Identifier: BSD-3-Clause

#define _GNU_SOURCE
#include "td_linux.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
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

int td_linux_memfd(const char *name) { return memfd_create(name, MFD_CLOEXEC); }

void td_linux_set_thread_name(const char *name) {
  char short_name[16];
  strncpy(short_name, name, 15);
  short_name[15] = 0;
  pthread_setname_np(pthread_self(), short_name);
}

// MARK: Swift costs

// The runtime's hook pointers (HeapObject.cpp, for instrumentation): with
// the switch on, swift_retain and its kin call through them. Weak, so a
// runtime without them reads as unsupported.
extern void *(*_swift_retain)(void *) __attribute__((weak));
extern void *(*_swift_retain_n)(void *, uint32_t) __attribute__((weak));
extern void (*_swift_release)(void *) __attribute__((weak));
extern void (*_swift_release_n)(void *, uint32_t) __attribute__((weak));
extern void *(*_swift_allocObject)(const void *, size_t, size_t) __attribute__((weak));
extern _Bool _swift_enableSwizzlingOfAllocationAndRefCountingFunctions_forInstrumentsOnly __attribute__((weak));

static void *(*original_retain)(void *);
static void *(*original_retain_n)(void *, uint32_t);
static void (*original_release)(void *);
static void (*original_release_n)(void *, uint32_t);
static void *(*original_alloc)(const void *, size_t, size_t);
static _Thread_local td_swift_costs costs;

static void *counting_retain(void *object) {
  costs.retains++;
  return original_retain(object);
}
static void *counting_retain_n(void *object, uint32_t n) {
  costs.retains += n;
  return original_retain_n(object, n);
}
static void counting_release(void *object) {
  costs.releases++;
  original_release(object);
}
static void counting_release_n(void *object, uint32_t n) {
  costs.releases += n;
  original_release_n(object, n);
}
static void *counting_alloc(const void *metadata, size_t size, size_t align_mask) {
  costs.allocations++;
  return original_alloc(metadata, size, align_mask);
}

int td_swift_costs_install(void) {
  if (!&_swift_retain || !&_swift_retain_n || !&_swift_release || !&_swift_release_n || !&_swift_allocObject ||
      !&_swift_enableSwizzlingOfAllocationAndRefCountingFunctions_forInstrumentsOnly)
    return -1;
  if (original_retain) return 0;  // already counting
  original_retain = _swift_retain;
  original_retain_n = _swift_retain_n;
  original_release = _swift_release;
  original_release_n = _swift_release_n;
  original_alloc = _swift_allocObject;
  _swift_retain = counting_retain;
  _swift_retain_n = counting_retain_n;
  _swift_release = counting_release;
  _swift_release_n = counting_release_n;
  _swift_allocObject = counting_alloc;
  _swift_enableSwizzlingOfAllocationAndRefCountingFunctions_forInstrumentsOnly = 1;
  return 0;
}

td_swift_costs td_swift_costs_read(void) { return costs; }

// MARK: Passing descriptors

int td_linux_receive_fd(int socket) {
  char byte;
  struct iovec iov = {.iov_base = &byte, .iov_len = 1};
  union {
    struct cmsghdr header;
    char space[CMSG_SPACE(sizeof(int))];
  } control;
  struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.space, .msg_controllen = sizeof control.space};
  ssize_t n;
  do {
    n = recvmsg(socket, &msg, MSG_CMSG_CLOEXEC);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) {
    if (n == 0) errno = ECONNRESET;
    return -1;
  }
  struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
  if (!c || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len != CMSG_LEN(sizeof(int))) {
    errno = EPROTO;
    return -1;
  }
  int fd;
  memcpy(&fd, CMSG_DATA(c), sizeof fd);
  return fd;
}
