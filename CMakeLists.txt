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
add_library(IPCWire STATIC lib/ipc/wire/Alignment.swift)
set_target_properties(IPCWire PROPERTIES Swift_MODULE_NAME IPCWire)
target_include_directories(IPCWire INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
todhchai_tier0(IPCWire)

# Embedded test programs, run on the host by ctest.
add_executable(wire-smoke tests/embedded/WireSmoke.swift)
set_target_properties(wire-smoke PROPERTIES Swift_MODULE_NAME WireSmoke)
target_link_libraries(wire-smoke PRIVATE IPCWire)
todhchai_tier0(wire-smoke)
add_test(NAME embedded-ipc-wire COMMAND wire-smoke)
