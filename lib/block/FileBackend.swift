// SPDX-License-Identifier: BSD-3-Clause

// The hosted device: blocks in an image file. Cache policy maps onto
// Linux's page cache: `cached` reads and writes through it, `uncached`
// goes past it with O_DIRECT (or, where the file system refuses O_DIRECT,
// through it and out again as soon as Linux can), and `readOnce` reads
// through it and then drops what it read. A flush is fdatasync.

import BlockRing
import Glibc
import TDLinux

/// A failed system call, with its errno.
public struct HostError: Error, CustomStringConvertible, Sendable {
  public let call: String
  public let errno: Int32
  public var description: String { "\(call): \(String(cString: strerror(errno)))" }
}

public final class FileBackend: BlockBackend {
  public let blockSize: Int
  public let blockCount: UInt64
  public let readOnly: Bool
  let fd: Int32
  /// The same file opened O_DIRECT, or -1 if its file system won't.
  let direct: Int32

  /// Opens the image at `path`. With `blocks`, makes (or resizes) it to
  /// that many blocks.
  public init(path: String, blocks: UInt64? = nil, blockSize: Int = 4096, readOnly: Bool = false) throws(HostError) {
    let flags = readOnly ? O_RDONLY : O_RDWR
    fd = open(path, flags | O_CLOEXEC | (blocks == nil || readOnly ? 0 : O_CREAT), 0o644)
    guard fd >= 0 else { throw HostError(call: "open \(path)", errno: errno) }
    if let blocks, !readOnly {
      guard ftruncate(fd, off_t(blocks) * off_t(blockSize)) == 0 else {
        let e = errno
        close(fd)
        throw HostError(call: "ftruncate \(path)", errno: e)
      }
      blockCount = blocks
    } else {
      var st = stat()
      fstat(fd, &st)
      blockCount = UInt64(st.st_size) / UInt64(blockSize)
    }
    direct = td_linux_open_direct(path, flags)
    self.blockSize = blockSize
    self.readOnly = readOnly
  }

  deinit {
    close(fd)
    if direct >= 0 { close(direct) }
  }

  /// Whether `uncached` really goes past the page cache.
  public var hasDirect: Bool { direct >= 0 }

  public func read(_ block: UInt64, into buffer: UnsafeMutableRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let offset = off_t(block) * off_t(blockSize)
    let file = policy == .uncached && direct >= 0 ? direct : fd
    var done = 0
    while done < buffer.count {
      let n = pread(file, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return .io }
      done += n
    }
    if policy != .cached && file == fd { posix_fadvise(fd, offset, off_t(buffer.count), POSIX_FADV_DONTNEED) }
    return .ok
  }

  public func write(_ block: UInt64, from buffer: UnsafeRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let offset = off_t(block) * off_t(blockSize)
    let file = policy == .uncached && direct >= 0 ? direct : fd
    var done = 0
    while done < buffer.count {
      let n = pwrite(file, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return .io }
      done += n
    }
    // Linux starts writing the pages back, and drops them once clean.
    if policy == .uncached && file == fd { posix_fadvise(fd, offset, off_t(buffer.count), POSIX_FADV_DONTNEED) }
    return .ok
  }

  public func flush() -> BlockStatus { fdatasync(fd) == 0 ? .ok : .io }
}
