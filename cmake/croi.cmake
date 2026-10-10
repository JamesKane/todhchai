# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 0 built for croi's user space (M3): Embedded Swift for croi's
# triples with croi's user flags (../croi/cmake/arch/<arch>.cmake,
# ../croi/cmake/CroiUser.cmake). Programs are static ELF executables linked
# by ld.lld at croi's user address, with our runtime (lib/sys/native).
# TODHCHAI_ARCH (amd64, arm64, rv64) picks the arch; the presets set it.

# CMake's compiler checks configure projects of their own: they need it too.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES TODHCHAI_ARCH)
if(NOT TODHCHAI_ARCH)
  message(FATAL_ERROR "Configure with a preset, e.g. `cmake --preset native-amd64`")
endif()

# The toolchain .swift-version pins, found through swiftly.
execute_process(COMMAND swiftly use --print-location
                WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}/..
                OUTPUT_VARIABLE _toolchain OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0 OR NOT EXISTS "${_toolchain}/usr/bin/swiftc")
  message(FATAL_ERROR "Could not locate the Swift toolchain through swiftly")
endif()
set(_bin "${_toolchain}/usr/bin")

set(CMAKE_SYSTEM_NAME Generic)
if(TODHCHAI_ARCH STREQUAL amd64)
  set(CMAKE_SYSTEM_PROCESSOR x86_64)
  set(_swift_triple x86_64-unknown-none-elf)
  set(_clang_triple x86_64-unknown-none-elf)
  set(_user_cflags)
elseif(TODHCHAI_ARCH STREQUAL arm64)
  set(CMAKE_SYSTEM_PROCESSOR aarch64)
  set(_swift_triple aarch64-none-none-elf)
  set(_clang_triple aarch64-unknown-none-elf)
  set(_user_cflags)
elseif(TODHCHAI_ARCH STREQUAL rv64)
  set(CMAKE_SYSTEM_PROCESSOR riscv64)
  set(_swift_triple riscv64-none-none-eabi)
  set(_clang_triple riscv64-unknown-none-elf)
  # croi's user flags say lp64d; the toolchain's prebuilt rv64 libraries
  # (the Unicode tables) are lp64, and ld.lld won't mix the two. Our
  # programs call croi only through syscalls, so lp64 costs nothing but
  # floats passed in integer registers; rv64gc still has the FP unit.
  set(_user_cflags -march=rv64gc -mabi=lp64 -mcmodel=medany)
else()
  message(FATAL_ERROR "Unknown TODHCHAI_ARCH '${TODHCHAI_ARCH}': amd64, arm64 or rv64")
endif()

set(CMAKE_ASM_COMPILER   "${_bin}/clang")
set(CMAKE_Swift_COMPILER "${_bin}/swiftc")
set(CMAKE_LINKER         "${_bin}/ld.lld")
set(CMAKE_AR             "${_bin}/llvm-ar")
set(CMAKE_RANLIB         "${_bin}/llvm-ranlib")
set(CMAKE_ASM_COMPILER_TARGET   "${_clang_triple}")
set(CMAKE_Swift_COMPILER_TARGET "${_swift_triple}")

# Nothing here can produce a hosted executable.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(_cg ${_user_cflags} -ffunction-sections -fdata-sections -fno-omit-frame-pointer)
list(JOIN _cg " " _cg_str)
set(CMAKE_ASM_FLAGS_INIT "${_cg_str}")

set(_swift -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes
           -strict-memory-safety -Werror StrictMemorySafety
           -Werror EmbeddedRestrictions -Wwarning PerformanceHints
           -Xfrontend -function-sections)
foreach(_f IN LISTS _cg)
  list(APPEND _swift -Xcc ${_f})
endforeach()
list(JOIN _swift " " CMAKE_Swift_FLAGS_INIT)
# CMake's Swift support overwrites the *_INIT values for configurations, so
# the configuration flags are seeded into the cache instead.
set(CMAKE_Swift_FLAGS_DEBUG "-Onone -g" CACHE STRING "")
set(CMAKE_Swift_FLAGS_RELEASE "-Osize" CACHE STRING "")
set(CMAKE_Swift_FLAGS_RELWITHDEBINFO "-Osize -g" CACHE STRING "")

# Embedded Swift requires whole-module compilation.
set(CMAKE_Swift_COMPILATION_MODE wholemodule)

# Programs: static, at croi's user address (ProgramLoader and userboot
# take ET_EXEC), with Swift's Unicode tables (String comparison needs
# them; they are the toolchain's).
set(TODHCHAI_UNICODE_TABLES
    "${_toolchain}/usr/lib/swift/embedded/${_swift_triple}/libswiftUnicodeDataTables.a")
set(CMAKE_Swift_LINK_EXECUTABLE
    "<CMAKE_LINKER> -static -e _start --image-base=0x1000000 -zseparate-loadable-segments -zmax-page-size=4096 -znoexecstack -zstack-size=262144 --gc-sections --build-id=sha1 <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES> ${TODHCHAI_UNICODE_TABLES}")
