// SPDX-License-Identifier: BSD-3-Clause

// Memory (sdk.md §8, principle 4): reserve address space, then commit,
// decommit, protect and release parts of it. The arena and scratch arenas
// (Arena.swift) are built on these.

import Glibc

public enum MemoryError: Error, Equatable {
  case system(Int32)
  /// A range not aligned to the page size.
  case misaligned
}

public enum Protection: Sendable {
  case none, read, readWrite
  var flags: Int32 {
    switch self {
    case .none: PROT_NONE
    case .read: PROT_READ
    case .readWrite: PROT_READ | PROT_WRITE
    }
  }
}

public enum Memory {
  public static let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))

  /// Reserves `bytes` of address space, rounded up to pages, with no access
  /// and no memory behind it.
  public static func reserve(_ bytes: Int) throws(MemoryError) -> UnsafeMutableRawBufferPointer {
    let size = (bytes + pageSize - 1) & ~(pageSize - 1)
    let p = mmap(nil, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0)
    guard let p, p != MAP_FAILED else { throw .system(errno) }
    return UnsafeMutableRawBufferPointer(start: p, count: size)
  }

  /// Makes a page-aligned range readable and writable; it reads as zero
  /// until written.
  public static func commit(_ range: UnsafeMutableRawBufferPointer) throws(MemoryError) {
    try protect(range, .readWrite)
  }

  /// Gives a range's memory back and removes access; its address space
  /// stays reserved.
  public static func decommit(_ range: UnsafeMutableRawBufferPointer) throws(MemoryError) {
    try check(range)
    guard madvise(range.baseAddress, range.count, MADV_DONTNEED) == 0 else { throw .system(errno) }
    try protect(range, .none)
  }

  public static func protect(_ range: UnsafeMutableRawBufferPointer, _ protection: Protection) throws(MemoryError) {
    try check(range)
    guard mprotect(range.baseAddress, range.count, protection.flags) == 0 else { throw .system(errno) }
  }

  /// Releases a reservation.
  public static func release(_ range: UnsafeMutableRawBufferPointer) {
    munmap(range.baseAddress, range.count)
  }

  static func check(_ range: UnsafeMutableRawBufferPointer) throws(MemoryError) {
    guard let base = range.baseAddress, Int(bitPattern: base) % pageSize == 0, range.count % pageSize == 0 else {
      throw .misaligned
    }
  }
}
