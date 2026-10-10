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
  if(TODHCHAI_MACROS)
    target_compile_options(${target} PRIVATE
      "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-load-plugin-executable ${TODHCHAI_MACROS}#IPCMacros>")
  endif()
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

# ELF executables: the native loader reads programs with it.
add_library(Elf STATIC lib/elf/Elf.swift)
set_target_properties(Elf PROPERTIES Swift_MODULE_NAME Elf)
target_include_directories(Elf INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(Elf)

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
    lib/sys/native/Start.swift lib/sys/native/Stdout.swift lib/sys/native/Heap.swift lib/sys/native/Thread.swift)
  set_target_properties(LibSys PROPERTIES Swift_MODULE_NAME LibSys)
  target_include_directories(LibSys PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/lib/sys/native/include
                                    INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(LibSys PUBLIC LibC)
  todhchai_tier0(LibSys)
  set(_sys_backend lib/sys/backend/native/Kernel.swift lib/sys/backend/native/Loader.swift)
else()
  set(_sys_backend lib/sys/backend/stub/Kernel.swift)
endif()
add_library(Sys STATIC lib/sys/api/Handles.swift lib/sys/api/Objects.swift lib/sys/api/Lock.swift ${_sys_backend})
set_target_properties(Sys PROPERTIES Swift_MODULE_NAME Sys)
target_include_directories(Sys INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Sys PUBLIC SysABI)
if(TODHCHAI_NATIVE)
  target_link_libraries(Sys PUBLIC LibSys Elf)
endif()
todhchai_tier0(Sys)

# The block service's rings.
add_library(BlockRing STATIC lib/block/ring/Ring.swift)
set_target_properties(BlockRing PROPERTIES Swift_MODULE_NAME BlockRing)
target_include_directories(BlockRing INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(BlockRing)

# The services' stack (M3c): tracing, the IPC runtime, Node, the launcher,
# block and fs. Protocols expand through the @IPCLibrary macro, whose
# plugin SwiftPM builds (`swift build` first).
set(TODHCHAI_MACROS ${CMAKE_CURRENT_SOURCE_DIR}/.build/debug/IPCMacros)
if(NOT EXISTS ${TODHCHAI_MACROS})
  message(FATAL_ERROR "No IPC macro plugin at ${TODHCHAI_MACROS}: run `swift build` first")
endif()

add_library(TraceFormat STATIC lib/trace/format/Format.swift)
set_target_properties(TraceFormat PROPERTIES Swift_MODULE_NAME TraceFormat)
target_include_directories(TraceFormat INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(TraceFormat)

# Both Embedded builds record nothing yet (no Glibc for the host's file
# region; croi's comes with M3e).
if(TODHCHAI_NATIVE)
  set(_trace_region lib/trace/writer/native/Region.swift)
else()
  set(_trace_region lib/trace/writer/stub/Region.swift)
endif()
add_library(Trace STATIC lib/trace/writer/Trace.swift ${_trace_region})
set_target_properties(Trace PROPERTIES Swift_MODULE_NAME Trace)
target_include_directories(Trace PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/lib/trace/c/include
                                 INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Trace PUBLIC TraceFormat)
if(TODHCHAI_NATIVE)
  target_link_libraries(Trace PUBLIC Sys)
endif()
todhchai_tier0(Trace)

add_library(IPC STATIC
  lib/ipc/runtime/Codec.swift lib/ipc/runtime/Connection.swift lib/ipc/runtime/Dispatcher.swift
  lib/ipc/runtime/Errors.swift lib/ipc/runtime/Macros.swift)
set_target_properties(IPC PROPERTIES Swift_MODULE_NAME IPC)
target_include_directories(IPC INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(IPC PUBLIC IPCWire Sys Trace)
todhchai_tier0(IPC)

file(GLOB _node_sources ${CMAKE_CURRENT_SOURCE_DIR}/lib/node/*.swift)
add_library(Node STATIC ${_node_sources})
set_target_properties(Node PROPERTIES Swift_MODULE_NAME Node)
target_include_directories(Node INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Node PUBLIC IPC)
todhchai_tier0(Node)

file(GLOB _launch_sources ${CMAKE_CURRENT_SOURCE_DIR}/lib/launch/*.swift)
add_library(Launch STATIC ${_launch_sources})
set_target_properties(Launch PROPERTIES Swift_MODULE_NAME Launch)
target_include_directories(Launch INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Launch PUBLIC Node IPC)
todhchai_tier0(Launch)

# The block service, less its hosted backend (an image file, FileBackend).
add_library(Block STATIC lib/block/Block.swift lib/block/Client.swift lib/block/Service.swift lib/block/VMOBackend.swift)
set_target_properties(Block PROPERTIES Swift_MODULE_NAME Block)
target_include_directories(Block INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Block PUBLIC BlockRing Node IPC)
todhchai_tier0(Block)

file(GLOB _fs_sources ${CMAKE_CURRENT_SOURCE_DIR}/lib/fs/*.swift)
add_library(Fs STATIC ${_fs_sources})
set_target_properties(Fs PROPERTIES Swift_MODULE_NAME Fs)
target_include_directories(Fs INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Fs PUBLIC Block BlockRing Node IPC Taisce)
todhchai_tier0(Fs)

# N0's programs' bodies, shared by the hosted and native boots.
add_library(Services STATIC lib/services/Services.swift)
set_target_properties(Services PROPERTIES Swift_MODULE_NAME Services)
target_include_directories(Services INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(Services PUBLIC Fs Block Launch Node IPC Taisce)
todhchai_tier0(Services)

# croi's boot data (K9b): firmware's items, Zircon's ZBI format (M3h).
add_library(ZBI STATIC lib/zbi/BootData.swift)
set_target_properties(ZBI PROPERTIES Swift_MODULE_NAME ZBI)
target_include_directories(ZBI INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(ZBI)

# PCI configuration space and enumeration, and devmgr's model (M3g).
# Device registers are read through _Volatile.
add_library(PCI STATIC lib/pci/Config.swift lib/pci/ECAM.swift lib/pci/Enumerate.swift)
set_target_properties(PCI PROPERTIES Swift_MODULE_NAME PCI)
target_include_directories(PCI INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_compile_options(PCI PRIVATE "SHELL:-enable-experimental-feature Volatile")
todhchai_tier0(PCI)

add_library(DevMgr STATIC lib/devmgr/Devices.swift lib/devmgr/Firmware.swift lib/devmgr/Grants.swift lib/devmgr/Rules.swift)
set_target_properties(DevMgr PROPERTIES Swift_MODULE_NAME DevMgr)
target_include_directories(DevMgr INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
target_compile_options(DevMgr PRIVATE "SHELL:-enable-experimental-feature Volatile")
target_link_libraries(DevMgr PUBLIC PCI Sys TDACPI)
todhchai_tier0(DevMgr)

# bootfs images: td writes them, the native launcher reads them.
add_library(Bootfs STATIC lib/bootfs/Bootfs.swift)
set_target_properties(Bootfs PROPERTIES Swift_MODULE_NAME Bootfs)
target_include_directories(Bootfs INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(Bootfs)

if(TODHCHAI_NATIVE)
  # A recording on croi (M3f): kernel rings and processes' regions.
  add_library(TraceSession STATIC lib/trace/session/Session.swift)
  set_target_properties(TraceSession PROPERTIES Swift_MODULE_NAME TraceSession)
  target_include_directories(TraceSession INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(TraceSession PUBLIC Trace Sys)
  todhchai_tier0(TraceSession)

  # A program for bootfs: bin/<name>, linked with libsys.
  function(todhchai_program name)
    add_executable(${name} ${ARGN})
    string(REPLACE "-" "_" _module ${name})
    set_target_properties(${name} PROPERTIES Swift_MODULE_NAME ${_module}
                          RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    target_link_libraries(${name} PRIVATE LibSys)
    todhchai_tier0(${name})
  endfunction()

  todhchai_program(launcher boot/programs/launcher/Main.swift boot/programs/launcher/Boot.swift)
  target_link_libraries(launcher PRIVATE Launch Bootfs Sys)
  # N0's programs (M3e), over the bodies the hosted boot shares (lib/services).
  todhchai_program(block boot/programs/block/Main.swift)
  target_link_libraries(block PRIVATE Services)
  todhchai_program(fs boot/programs/fs/Main.swift)
  target_link_libraries(fs PRIVATE Services)
  todhchai_program(catalog boot/programs/catalog/Main.swift)
  target_link_libraries(catalog PRIVATE Services)
  # devmgr and its first driver (M3g).
  todhchai_program(devmgr boot/programs/devmgr/Main.swift boot/programs/launcher/Boot.swift)
  target_link_libraries(devmgr PRIVATE DevMgr PCI TDACPI ZBI Launch Bootfs Node IPC Sys)
  todhchai_program(edu boot/programs/edu/Main.swift)
  target_link_libraries(edu PRIVATE DevMgr Launch Node IPC Sys)
  # Tests that run on croi: td boot --test --next bin/<name>.
  todhchai_program(sys-test tests/native/SysTest.swift)
  target_link_libraries(sys-test PRIVATE Sys)
  todhchai_program(services-test tests/native/ServicesTest.swift)
  target_link_libraries(services-test PRIVATE Fs Block Node IPC Sys)
  # The launcher's test: td boot --test --manifests tests/native/manifests
  # --cmdline launcher.until=launch-test.
  todhchai_program(tree-service tests/native/TreeService.swift)
  target_link_libraries(tree-service PRIVATE Launch Node IPC Sys)
  todhchai_program(launch-test tests/native/LaunchTest.swift)
  target_link_libraries(launch-test PRIVATE Launch Node IPC Sys)
  # N0's exit on croi: td boot --test --next bin/n0-exit --manifests boot/native.
  todhchai_program(n0-exit tests/native/N0Exit.swift boot/programs/launcher/Boot.swift)
  target_link_libraries(n0-exit PRIVATE Launch Bootfs Fs Node Sys TraceSession)
  # devmgr's test: td boot --test --manifests tests/native/devices
  # --cmdline launcher.until=devices-test -- -device edu.
  todhchai_program(devices-test tests/native/DevicesTest.swift)
  target_link_libraries(devices-test PRIVATE Launch Node IPC Sys)
  # A0's budgets on croi: td boot --test --next bin/acpi-bench --data .cache/acpi/NAME.
  todhchai_program(acpi-bench tests/native/ACPIBench.swift boot/programs/launcher/Boot.swift)
  target_link_libraries(acpi-bench PRIVATE TDACPI Bootfs Sys)
  todhchai_program(spawn-probe tests/native/SpawnProbe.swift)
  target_link_libraries(spawn-probe PRIVATE Sys)
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

add_executable(pci-smoke tests/embedded/PCISmoke.swift)
set_target_properties(pci-smoke PROPERTIES Swift_MODULE_NAME PCISmoke)
target_link_libraries(pci-smoke PRIVATE PCI)
todhchai_tier0(pci-smoke)
add_test(NAME embedded-pci COMMAND pci-smoke)

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
