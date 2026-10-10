// SPDX-License-Identifier: BSD-3-Clause

// bin/launcher, natively: the program croi's userboot starts from bootfs.
// For now (M3a) it proves the runtime: arguments, environment, startup
// handles, the heap's two paths and String comparison, then exits 0. The
// launcher proper (lib/launch) takes its place in M3d.

import LibSys

@main struct Launcher {
  static func main() {
    print("launcher: Todhchai on croi")
    print("launcher: \(Arguments.strings.count) argument(s), \(Environment.strings.count) environment string(s)")
    print("launcher: \(StartupHandles.remaining.count) startup handle(s)")

    // Small blocks from the size classes, a large one mapped on its own.
    var small: [[UInt8]] = []
    for i in 0..<1000 { small.append([UInt8](repeating: UInt8(truncatingIfNeeded: i), count: i % 300)) }
    let large = [UInt64](repeating: 7, count: 100_000)
    var sum: UInt64 = 0
    for block in small { for b in block { sum &+= UInt64(b) } }
    for v in large { sum &+= v }
    small.removeAll()
    // Σ (i mod 256)(i mod 300) for i < 1000, plus 7 × 100 000.
    guard sum == 17_695_004 else {
      print("launcher: heap checksum \(sum), not 17695004")
      exit(1)
    }

    let greeting = "dia duit"
    let same = String(decoding: Array("dia duit".utf8), as: UTF8.self)
    guard greeting == same else {
      print("launcher: String comparison failed")
      exit(1)
    }
    print("launcher: ready")
  }
}
