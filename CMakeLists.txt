# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 0 build: Embedded Swift, one tree per configuration in build/<preset>.
# The hosted build (tier 1, tools, most tests) is SwiftPM's (Package.swift).

cmake_minimum_required(VERSION 3.29)
project(todhchai LANGUAGES Swift)
enable_testing()

# Options every tier 0 target shares.
function(todhchai_tier0 target)
  target_compile_options(${target} PRIVATE -parse-as-library)
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

add_library(TDACPI STATIC lib/acpi/Tables.swift lib/acpi/Namespace.swift lib/acpi/Loader.swift lib/acpi/Objects.swift lib/acpi/Interpreter.swift lib/acpi/Regions.swift lib/acpi/Interfaces.swift)
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
