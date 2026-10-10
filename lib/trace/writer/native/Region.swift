// SPDX-License-Identifier: BSD-3-Clause

// The trace region, natively: none yet. Every trace point costs its load
// and branch and records nothing, until the native trace (M3f) gives each
// process a region beside croi's kernel rings. The thread-ring hooks the
// host's C file provides (td_trace_cpu.c, with thread-local storage croi's
// threads don't have yet) are defined here for the link, and unused.

import TraceFormat

extension Trace {
  /// Natively, nothing to start from yet: false.
  @discardableResult
  public static func startFromEnvironment() -> Bool {
    startAttempted = true
    return false
  }

  /// Natively, no regions yet: false.
  @discardableResult
  public static func start(path: String, categories: TraceCategory = .all, circular: Bool = false,
                           rings: Int = 64, recordsPerRing: Int = 1 << 15) -> Bool {
    false
  }
}

@c func td_trace_thread_ring() -> UnsafeMutableRawPointer? { nil }
@c func td_trace_set_thread_ring(_ ring: UnsafeMutableRawPointer?) {}
