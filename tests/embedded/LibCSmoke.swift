// SPDX-License-Identifier: BSD-3-Clause

// LibC built as Embedded Swift on the host: a few calls through each
// function. The differential tests (tests/libc) are the thorough ones.

import LibC

@main struct LibCSmoke {
  static func main() {
    var a: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f, 0]  // "hello"
    var b = [UInt8](repeating: 0, count: 6)
    a.withUnsafeMutableBytes { pa in
      b.withUnsafeMutableBytes { pb in
        let p = pa.baseAddress!, q = pb.baseAddress!
        _ = unsafe LibC.memcpy(q, p, 6)
        check(unsafe LibC.memcmp(p, q, 6) == 0, "memcpy, memcmp")
        let s = unsafe p.assumingMemoryBound(to: CChar.self)
        check(unsafe LibC.strlen(s) == 5, "strlen")
        let first = unsafe LibC.strchr(s, 0x6c), last = unsafe LibC.strrchr(s, 0x6c)
        check(unsafe first.map { unsafe $0 - UnsafePointer(s) } == 2, "strchr")
        check(unsafe last.map { unsafe $0 - UnsafePointer(s) } == 3, "strrchr")
        _ = unsafe LibC.memmove(p + 1, p, 4)
        check(unsafe p.load(fromByteOffset: 1, as: UInt8.self) == 0x68, "memmove")
      }
    }
    print("embedded LibC: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
