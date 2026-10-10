// SPDX-License-Identifier: BSD-3-Clause

// stdout over croi's debuglog: Embedded Swift's print writes through
// putchar, and each line goes out as one debuglog record (at most 216
// bytes; a longer line is split). Before stdout is set up, or if the
// process was started without one, writes go nowhere.

import Synchronization
import TDNative

enum Stdout {
  static let recordMax = 216

  nonisolated(unsafe) static var log: UInt32 = 0
  nonisolated(unsafe) static var line = InlineArray<216, UInt8>(repeating: 0)
  nonisolated(unsafe) static var count = 0
  static let lock = RuntimeLock()

  static func put(_ byte: UInt8) {
    if byte == UInt8(ascii: "\n") {
      flushLocked()
      return
    }
    line[count] = byte
    count += 1
    if count == recordMax { flushLocked() }
  }

  static func write(_ text: StaticString) {
    lock.locked {
      unsafe text.withUTF8Buffer { buffer in for unsafe b in unsafe buffer { put(b) } }
    }
  }

  static func flush() { lock.locked { flushLocked() } }

  static func flushLocked() {
    guard count > 0 else { return }
    if log != 0 {
      unsafe withUnsafePointer(to: &line) { p in
        _ = unsafe td_syscall6(
          SyscallNumber.debuglogWrite, UInt64(log), 0, UInt64(UInt(bitPattern: p)), UInt64(count), 0, 0)
      }
    }
    count = 0
  }
}

@c public func putchar(_ c: Int32) -> Int32 {
  Stdout.lock.locked { Stdout.put(UInt8(truncatingIfNeeded: c)) }
  return c
}

/// The runtime's lock: Sys.Lock's design (lib/sys/api/Lock.swift) over
/// croi's futexes, for what sits below Sys (the heap, stdout). Not a
/// class: the heap's lock can't come from the heap.
struct RuntimeLock: ~Copyable, Sendable {
  let word = Atomic<UInt32>(0)

  borrowing func locked<R>(_ body: () -> R) -> R {
    if !word.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged {
      while word.exchange(2, ordering: .acquiring) != 0 {
        _ = unsafe td_syscall6(SyscallNumber.futexWait, address, 2, 0, UInt64.max >> 1, 0, 0)
      }
    }
    defer {
      if word.exchange(0, ordering: .releasing) == 2 {
        _ = unsafe td_syscall6(SyscallNumber.futexWake, address, 1, 0, 0, 0, 0)
      }
    }
    return body()
  }

  var address: UInt64 { unsafe withUnsafePointer(to: word) { UInt64(UInt(bitPattern: $0)) } }
}
