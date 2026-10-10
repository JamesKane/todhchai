// SPDX-License-Identifier: BSD-3-Clause

// The heap: memory from VMOs mapped into the root VMAR. Requests of up to
// 4 KiB (with their 16-byte header) at alignments up to 16 come from size
// classes (32 B to 4 KiB, powers of two) carved from 256 KiB chunks and
// kept on per-class free lists; anything else gets a mapping of its own,
// unmapped when freed. Embedded Swift allocates through posix_memalign and
// free. Correct first, then measured (principle 9).

import TDNative

enum Heap {
  static let classes = 8
  static let smallest = 32
  static let chunkSize = 256 * 1024
  static let pageSize = 4096
  /// A header's tag: a class index, or this bit and a mapping's length.
  static let largeBit: UInt64 = 1 << 63

  nonisolated(unsafe) static var vmar: UInt32 = 0
  nonisolated(unsafe) static var free = InlineArray<8, UInt>(repeating: 0)
  nonisolated(unsafe) static var chunk: UInt = 0
  nonisolated(unsafe) static var chunkLeft = 0
  static let lock = SpinLock()

  /// A fresh read-write mapping of `length` bytes (a page multiple), or 0.
  static func map(_ length: Int) -> UInt {
    var vmo: UInt32 = 0
    let made = unsafe withUnsafeMutablePointer(to: &vmo) { p in
      unsafe td_syscall6(SyscallNumber.vmoCreate, UInt64(length), 0, UInt64(UInt(bitPattern: p)), 0, 0, 0)
    }
    guard made == 0 else { return 0 }
    defer { _ = unsafe td_syscall6(SyscallNumber.handleClose, UInt64(vmo), 0, 0, 0, 0, 0) }
    var address: UInt64 = 0
    let readWrite: UInt64 = 1 | 2  // CROI_VM_PERM_READ | CROI_VM_PERM_WRITE
    let mapped = unsafe withUnsafeMutablePointer(to: &address) { p in
      unsafe td_syscall6(
        SyscallNumber.vmarMap, UInt64(vmar) | readWrite << 32, 0, UInt64(vmo), 0, UInt64(length),
        UInt64(UInt(bitPattern: p)))
    }
    return mapped == 0 ? UInt(address) : 0
  }

  static func unmap(_ address: UInt, _ length: Int) {
    _ = unsafe td_syscall6(SyscallNumber.vmarUnmap, UInt64(vmar), UInt64(address), UInt64(length), 0, 0, 0)
  }

  static func classIndex(_ size: Int) -> Int? {
    var c = 0
    var block = smallest
    while block < size + 16 {
      c += 1
      block <<= 1
      if c == classes { return nil }
    }
    return c
  }

  static func allocate(_ size: Int, _ alignment: Int) -> UInt {
    if alignment <= 16, let c = classIndex(size) {
      return lock.locked { () -> UInt in
        var block = free[c]
        if block != 0 {
          free[c] = unsafe UnsafePointer<UInt>(bitPattern: block)!.pointee
        } else {
          let blockSize = smallest << c
          if chunkLeft < blockSize {
            chunk = map(chunkSize)
            guard chunk != 0 else { return 0 }
            chunkLeft = chunkSize
          }
          block = chunk
          chunk += UInt(blockSize)
          chunkLeft -= blockSize
        }
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: block)!.pointee = UInt64(c)
        return block + 16
      }
    }
    let align = max(alignment, 16)
    let length = (size + align + 16 + pageSize - 1) & ~(pageSize - 1)
    let base = map(length)
    guard base != 0 else { return 0 }
    let user = (base + 16 + UInt(align) - 1) & ~(UInt(align) - 1)
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: user - 16)!.pointee = largeBit | UInt64(length)
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: user - 8)!.pointee = UInt64(base)
    return user
  }

  static func release(_ user: UInt) {
    let tag = unsafe UnsafePointer<UInt64>(bitPattern: user - 16)!.pointee
    if tag & largeBit != 0 {
      let base = unsafe UnsafePointer<UInt64>(bitPattern: user - 8)!.pointee
      unmap(UInt(base), Int(tag & ~largeBit))
      return
    }
    let c = Int(tag)
    precondition(c < classes, "free: not a heap block")
    let block = user - 16
    lock.locked {
      unsafe UnsafeMutablePointer<UInt>(bitPattern: block)!.pointee = free[c]
      free[c] = block
    }
  }
}

@c public func posix_memalign(
  _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ alignment: Int, _ size: Int
) -> Int32 {
  let p = Heap.allocate(size, alignment)
  guard p != 0 else { return 12 }  // ENOMEM
  unsafe out.pointee = UnsafeMutableRawPointer(bitPattern: p)
  return 0
}

@c public func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: Heap.allocate(size, 16))
}

@c public func free(_ p: UnsafeMutableRawPointer?) {
  guard let p = unsafe p else { return }
  Heap.release(UInt(bitPattern: p))
}
