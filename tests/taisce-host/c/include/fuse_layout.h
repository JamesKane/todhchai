// SPDX-License-Identifier: BSD-3-Clause
// The host's FUSE structure sizes, from <linux/fuse.h>, to check
// lib/taisce-host/FuseProtocol.swift's against.
#include <stddef.h>
#include <sys/types.h>
size_t fuse_layout_size(const char *name);
size_t fuse_layout_offset(const char *field);
// <sys/xattr.h> isn't in Swift's Glibc module; the exit test sets and
// reads attributes through these.
int fuse_test_setxattr(const char *path, const char *name, const void *value, size_t size);
ssize_t fuse_test_getxattr(const char *path, const char *name, void *value, size_t size);
