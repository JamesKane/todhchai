# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 0 code built as Embedded Swift for the host (x86_64 Linux), with the
# flags croi uses (../croi/cmake/toolchain.cmake). Libraries built here are
# proved Embedded-clean, and their test programs run on the host. Builds
# for croi's user-space triples come with M3.

set(TODHCHAI_EMBEDDED_TRIPLE x86_64-unknown-linux-gnu)

set(_swift -target ${TODHCHAI_EMBEDDED_TRIPLE}
           -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes
           -strict-memory-safety -Werror StrictMemorySafety
           -Werror EmbeddedRestrictions -Wwarning PerformanceHints)
list(JOIN _swift " " CMAKE_Swift_FLAGS_INIT)
# CMake's Swift support overwrites the *_INIT values for configurations, so
# the configuration flags are seeded into the cache instead.
set(CMAKE_Swift_FLAGS_DEBUG "-Onone -g" CACHE STRING "")
set(CMAKE_Swift_FLAGS_RELEASE "-Osize" CACHE STRING "")
set(CMAKE_Swift_FLAGS_RELWITHDEBINFO "-Osize -g" CACHE STRING "")

# -parse-as-library is per target (todhchai_tier0 in CMakeLists.txt): CMake's
# compiler check builds a script-style main.swift.

# Embedded Swift requires whole-module compilation.
set(CMAKE_Swift_COMPILATION_MODE wholemodule)
