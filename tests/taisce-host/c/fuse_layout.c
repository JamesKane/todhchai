// SPDX-License-Identifier: BSD-3-Clause
#include "fuse_layout.h"
#include <linux/fuse.h>
#include <string.h>
#include <sys/xattr.h>

size_t fuse_layout_size(const char *n) {
#define S(t) if (!strcmp(n, #t)) return sizeof(struct t);
  S(fuse_in_header) S(fuse_out_header) S(fuse_attr) S(fuse_entry_out) S(fuse_attr_out) S(fuse_init_in)
  S(fuse_init_out) S(fuse_open_out) S(fuse_write_out) S(fuse_statfs_out) S(fuse_getxattr_out)
  S(fuse_setattr_in) S(fuse_read_in) S(fuse_write_in) S(fuse_create_in) S(fuse_release_in) S(fuse_mkdir_in)
  S(fuse_rename2_in) S(fuse_dirent)
#undef S
  if (!strcmp(n, "compat_setxattr_in")) return FUSE_COMPAT_SETXATTR_IN_SIZE;
  return 0;
}

size_t fuse_layout_offset(const char *f) {
  if (!strcmp(f, "create_in.mode")) return offsetof(struct fuse_create_in, mode);
  if (!strcmp(f, "setattr_in.size")) return offsetof(struct fuse_setattr_in, size);
  if (!strcmp(f, "setattr_in.mode")) return offsetof(struct fuse_setattr_in, mode);
  if (!strcmp(f, "setattr_in.uid")) return offsetof(struct fuse_setattr_in, uid);
  if (!strcmp(f, "write_in.size")) return offsetof(struct fuse_write_in, size);
  if (!strcmp(f, "init_out.max_write")) return offsetof(struct fuse_init_out, max_write);
  if (!strcmp(f, "init_out.max_pages")) return offsetof(struct fuse_init_out, max_pages);
  if (!strcmp(f, "attr.mode")) return offsetof(struct fuse_attr, mode);
  return (size_t)-1;
}

int fuse_test_setxattr(const char *path, const char *name, const void *value, size_t size) {
  return setxattr(path, name, value, size, 0);
}

ssize_t fuse_test_getxattr(const char *path, const char *name, void *value, size_t size) {
  return getxattr(path, name, value, size);
}
