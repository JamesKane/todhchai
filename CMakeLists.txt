# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 0 build: Embedded Swift, one tree per configuration in build/<preset>.
# The hosted build (tier 1, tools, most tests) is SwiftPM's (Package.swift).
#
# Two kinds of configuration: `embedded` builds tier 0 for the host and runs
# its test programs there; `native-<arch>` builds it for croi's user space
# (TODHCHAI_ARCH, cmake/croi.cmake) with libsys and the programs td boot
# puts in bootfs (build/native-<arch>/bin).

cmake_minimum_required(VERSION 3.29)
project(todhchai LANGUAGES Swift)
enable_testing()
if(TODHCHAI_ARCH)
  set(TODHCHAI_NATIVE ON)
  enable_language(ASM)
endif()

# Options every tier 0 target shares.
function(todhchai_tier0 target)
  target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>)
endfunction()

# Each tier 0 library: its sources, built as Embedded Swift.
add_library(IPCWire STATIC
  lib/ipc/wire/Alignment.swift lib/ipc/wire/Control.swift lib/ipc/wire/Decoder.swift
  lib/ipc/wire/Encoder.swift lib/ipc/wire/Errors.swift lib/ipc/wire/Header.swift
  lib/ipc/wire/Limits.swift lib/ipc/wire/Ordinal.swift)
set_target_properties(IPCWire PROPERTIES Swift_MODULE_NAME IPCWire)
target_include_directories(IPCWire INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(IPCWire)

add_library(LibC STATIC lib/libc/string/Memory.swift lib/libc/string/Strings.swift)
set_target_properties(LibC PROPERTIES Swift_MODULE_NAME LibC)
target_include_directories(LibC INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(LibC)
if(TODHCHAI_NATIVE)
  # The functions under their C names; no loop may become a call to them.
  target_sources(LibC PRIVATE lib/libc/native/Exports.swift)
  target_compile_options(LibC PRIVATE "SHELL:-Xllvm -disable-loop-idiom-all")
endif()

add_library(TDACPI STATIC lib/acpi/Tables.swift lib/acpi/Namespace.swift lib/acpi/Loader.swift lib/acpi/Objects.swift lib/acpi/Interpreter.swift lib/acpi/Regions.swift lib/acpi/Interfaces.swift lib/acpi/Resources.swift lib/acpi/Devices.swift)
set_target_properties(TDACPI PROPERTIES Swift_MODULE_NAME TDACPI)
target_include_directories(TDACPI INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(TDACPI)

add_library(TDCrypto STATIC lib/crypto/BLAKE3.swift)
set_target_properties(TDCrypto PROPERTIES Swift_MODULE_NAME TDCrypto)
target_include_directories(TDCrypto INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(TDCrypto)

add_library(TDUnicode STATIC lib/unicode/Normalization.swift lib/unicode/generated/Tables.swift)
set_target_properties(TDUnicode PROPERTIES Swift_MODULE_NAME TDUnicode)
target_include_directories(TDUnicode INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(TDUnicode)

add_library(Taisce STATIC
  lib/taisce/Allocator.swift lib/taisce/AttributeStore.swift lib/taisce/Attributes.swift lib/taisce/BlockDevice.swift lib/taisce/Bytes.swift lib/taisce/CRC32C.swift
  lib/taisce/BTree.swift lib/taisce/Engine.swift lib/taisce/Epochs.swift lib/taisce/FileReader.swift lib/taisce/FileReading.swift lib/taisce/Errors.swift lib/taisce/FileSystem.swift lib/taisce/Inode.swift lib/taisce/IntentLog.swift lib/taisce/Query.swift lib/taisce/SharedCache.swift lib/taisce/QueryEngine.swift
  lib/taisce/Node.swift lib/taisce/Pointer.swift
  lib/taisce/Store.swift
  lib/taisce/Superblock.swift lib/taisce/Volume.swift)
set_target_properties(Taisce PROPERTIES Swift_MODULE_NAME Taisce)
target_link_libraries(Taisce PUBLIC TDUnicode TDCrypto)
target_include_directories(Taisce INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(Taisce)

# Sys: croi's values, and the typed API: over croi's syscalls natively,
# over a stub that fails every call in the host's Embedded build.
add_library(SysABI STATIC lib/sys/abi/Values.swift)
set_target_properties(SysABI PROPERTIES Swift_MODULE_NAME SysABI)
target_include_directories(SysABI INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(SysABI)

if(TODHCHAI_NATIVE)
  # libsys: a native process's start, stdout and heap (lib/sys/native).
  add_library(LibSys STATIC
    lib/sys/native/entry/${TODHCHAI_ARCH}.S
    lib/sys/native/Start.swift lib/sys/native/Stdout.swift lib/sys/native/Heap.swift)
  set_target_properties(LibSys PROPERTIES Swift_MODULE_NAME LibSys)
  target_include_directories(LibSys PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/lib/sys/native/include
                                    INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(LibSys PUBLIC LibC)
  todhchai_tier0(LibSys)
  set(_sys_backend lib/sys/backend/native/Kernel.swift)
else()
  set(_sys_backend lib/sys/backend/stub/Kernel.swift)
endif()
add_library(Sys STATIC lib/sys/api/Handles.swift lib/sys/api/Objects.swift lib/sys/api/Lock.swift ${_sys_backend})
set_target_properties(Sys PROPERTIES Swift_MODULE_NAME Sys)
target_include_directories(Sys INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Sys PUBLIC SysABI)
if(TODHCHAI_NATIVE)
  target_link_libraries(Sys PUBLIC LibSys)
endif()
todhchai_tier0(Sys)

# The block service's rings.
add_library(BlockRing STATIC lib/block/ring/Ring.swift)
set_target_properties(BlockRing PROPERTIES Swift_MODULE_NAME BlockRing)
target_include_directories(BlockRing INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(BlockRing)

# bootfs images: td writes them, the native launcher reads them.
add_library(Bootfs STATIC lib/bootfs/Bootfs.swift)
set_target_properties(Bootfs PROPERTIES Swift_MODULE_NAME Bootfs)
target_include_directories(Bootfs INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(Bootfs)

if(TODHCHAI_NATIVE)
  # A program for bootfs: bin/<name>, linked with libsys.
  function(todhchai_program name)
    add_executable(${name} ${ARGN})
    string(REPLACE "-" "_" _module ${name})
    set_target_properties(${name} PROPERTIES Swift_MODULE_NAME ${_module}
                          RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    target_link_libraries(${name} PRIVATE LibSys)
    todhchai_tier0(${name})
  endfunction()

  todhchai_program(launcher boot/programs/launcher/Main.swift)
  # Tests that run on croi: td boot --test --next bin/<name>.
  todhchai_program(sys-test tests/native/SysTest.swift)
  target_link_libraries(sys-test PRIVATE Sys)
  return()
endif()

# Embedded test programs, run on the host by ctest.
add_executable(wire-smoke tests/embedded/WireSmoke.swift)
set_target_properties(wire-smoke PROPERTIES Swift_MODULE_NAME WireSmoke)
target_link_libraries(wire-smoke PRIVATE IPCWire)
todhchai_tier0(wire-smoke)
add_test(NAME embedded-ipc-wire COMMAND wire-smoke)

add_executable(libc-smoke tests/embedded/LibCSmoke.swift)
set_target_properties(libc-smoke PROPERTIES Swift_MODULE_NAME LibCSmoke)
target_link_libraries(libc-smoke PRIVATE LibC)
todhchai_tier0(libc-smoke)
add_test(NAME embedded-libc COMMAND libc-smoke)

add_executable(taisce-smoke tests/embedded/TaisceSmoke.swift)
set_target_properties(taisce-smoke PROPERTIES Swift_MODULE_NAME TaisceSmoke)
target_link_libraries(taisce-smoke PRIVATE Taisce)
todhchai_tier0(taisce-smoke)
add_test(NAME embedded-taisce COMMAND taisce-smoke)

add_executable(unicode-smoke tests/embedded/UnicodeSmoke.swift)
set_target_properties(unicode-smoke PROPERTIES Swift_MODULE_NAME UnicodeSmoke)
target_link_libraries(unicode-smoke PRIVATE TDUnicode)
todhchai_tier0(unicode-smoke)
add_test(NAME embedded-unicode COMMAND unicode-smoke)

add_executable(acpi-smoke tests/embedded/ACPISmoke.swift)
set_target_properties(acpi-smoke PROPERTIES Swift_MODULE_NAME ACPISmoke)
target_link_libraries(acpi-smoke PRIVATE TDACPI)
todhchai_tier0(acpi-smoke)
add_test(NAME embedded-acpi COMMAND acpi-smoke)

add_executable(crypto-smoke tests/embedded/CryptoSmoke.swift)
set_target_properties(crypto-smoke PROPERTIES Swift_MODULE_NAME CryptoSmoke)
target_link_libraries(crypto-smoke PRIVATE TDCrypto)
todhchai_tier0(crypto-smoke)
add_test(NAME embedded-crypto COMMAND crypto-smoke)

add_executable(sys-smoke tests/embedded/SysSmoke.swift)
set_target_properties(sys-smoke PROPERTIES Swift_MODULE_NAME SysSmoke)
target_link_libraries(sys-smoke PRIVATE Sys)
todhchai_tier0(sys-smoke)
add_test(NAME embedded-sys COMMAND sys-smoke)

add_executable(block-ring-smoke tests/embedded/BlockRingSmoke.swift)
set_target_properties(block-ring-smoke PROPERTIES Swift_MODULE_NAME BlockRingSmoke)
target_link_libraries(block-ring-smoke PRIVATE BlockRing)
todhchai_tier0(block-ring-smoke)
add_test(NAME embedded-block-ring COMMAND block-ring-smoke)
