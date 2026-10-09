// SPDX-License-Identifier: BSD-3-Clause

// What the hosted tools share.

import Glibc
import Taisce

public enum ToolSupport {
  /// 16 random bytes, from the kernel.
  public static func uuid() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 16)
    let fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC)
    if fd >= 0 {
      _ = b.withUnsafeMutableBytes { read(fd, $0.baseAddress, 16) }
      close(fd)
    }
    return b
  }

  /// "512M", "4G", "100000" (bytes); 1024-based.
  public static func size(_ text: String) -> UInt64? {
    let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
    if let last = text.last, let u = units[last.uppercased().first!], let n = UInt64(text.dropLast()) { return n * u }
    return UInt64(text)
  }

  /// The wall clock, in nanoseconds.
  public static var now: UInt64 {
    var t = timespec()
    clock_gettime(CLOCK_REALTIME, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
  }

  /// A line to standard output, unbuffered (so it shows before serving).
  public static func say(_ message: String) {
    let text = Array("\(message)\n".utf8)
    _ = text.withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
  }

  public static func fail(_ message: String) -> Never {
    let text = Array("\(message)\n".utf8)
    _ = text.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    exit(1)
  }
}
