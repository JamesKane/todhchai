// SPDX-License-Identifier: BSD-3-Clause

// The trace region in the host's Embedded build, which proves the writer
// Embedded-clean and has no kernel to get a region from: none. Every trace
// point costs its load and branch and records nothing. The thread-ring
// hooks (td_trace_cpu.c hosted, libsys natively) are defined here for the
// link, and unused.

import TraceFormat

extension Trace {
  /// Nothing to start from: false.
  @discardableResult
  public static func startFromEnvironment() -> Bool {
    startAttempted = true
    return false
  }

  /// No regions: false.
  @discardableResult
  public static func start(path: String, categories: TraceCategory = .all, circular: Bool = false,
                           rings: Int = 64, recordsPerRing: Int = 1 << 15) -> Bool {
    false
  }
}

@c func td_trace_thread_ring() -> UnsafeMutableRawPointer? { nil }
@c func td_trace_set_thread_ring(_ ring: UnsafeMutableRawPointer?) {}
