// SPDX-License-Identifier: BSD-3-Clause
// The host's FUSE structure sizes, from <linux/fuse.h>, to check
// lib/taisce-host/FuseProtocol.swift's against.
#include <stddef.h>
size_t fuse_layout_size(const char *name);
size_t fuse_layout_offset(const char *field);
