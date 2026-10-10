// SPDX-License-Identifier: BSD-3-Clause

// Each thread's block, found through the thread pointer (croi 869cb83's
// user TLS: FS's base on amd64, set through object_set_property;
// TPIDR_EL0 on arm64 and tp on rv64, set directly). Ours, not ELF TLS:
// tier 0 has no thread-local variables, only these slots. The main
// thread's block is static; another thread's sits at the top of its
// stack (lib/sys/backend/native), installed first thing as it starts.
//
//   0   self (amd64 reads %fs:0)
//   8   the thread's trace ring (lib/trace), 0 until it claims one
//   16  reserved, to 64

import TDNative

public enum ThreadBlock {
  public static let size = 64
  static let traceRing = 8
  static let setProperty: UInt64 = 104
  static let registerFS: UInt64 = 4  // CROI_PROP_REGISTER_FS

  nonisolated(unsafe) static var main = InlineArray<8, UInt64>(repeating: 0)

  /// Makes `block` (`size` bytes, zeroed, living as long as the thread) the
  /// calling thread's; `thread` is its own handle (amd64 needs it).
  public static func install(_ block: UnsafeMutableRawPointer, thread: UInt32) {
    unsafe block.storeBytes(of: UInt64(UInt(bitPattern: block)), as: UInt64.self)
    #if arch(x86_64)
      var value = UInt64(UInt(bitPattern: block))
      _ = unsafe withUnsafeMutablePointer(to: &value) { p in
        unsafe td_syscall6(setProperty, UInt64(thread), registerFS, UInt64(UInt(bitPattern: p)), 8, 0, 0)
      }
    #else
      unsafe td_set_thread_pointer(block)
    #endif
  }

  /// The main thread's, from td_start.
  static func installMain(thread: UInt32) {
    unsafe withUnsafeMutablePointer(to: &main) { p in unsafe install(UnsafeMutableRawPointer(p), thread: thread) }
  }

  /// The calling thread's block.
  @inline(__always)
  public static var current: UnsafeMutableRawPointer { unsafe td_thread_block()! }
}

/// The trace writer's per-thread ring (lib/trace's td_trace_cpu.h).
@c public func td_trace_thread_ring() -> UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: UInt(ThreadBlock.current.load(fromByteOffset: ThreadBlock.traceRing,
                                                                             as: UInt64.self)))
}

@c public func td_trace_set_thread_ring(_ ring: UnsafeMutableRawPointer?) {
  unsafe ThreadBlock.current.storeBytes(of: UInt64(UInt(bitPattern: ring)), toByteOffset: ThreadBlock.traceRing,
                                        as: UInt64.self)
}
