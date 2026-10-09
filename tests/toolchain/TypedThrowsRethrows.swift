// SPDX-License-Identifier: BSD-3-Clause
//
// Minimal reproduction of a Swift 6.4 miscompile, kept for reporting
// upstream and for checking later toolchains. Not part of either build.
//
//   swiftc -parse-as-library TypedThrowsRethrows.swift -o repro && ./repro
//
// Expected: "ok". With Swift 6.4 (swift-6.4-RELEASE, x86_64 Linux) the
// caught error is corrupt, and printing it crashes. Removing
// `throws(ReadError)` from the closure fixes it.

enum Status: Int32, Error { case ok = 0, bad = -11, wait = -22 }
struct ReadError: Error { var status: Status; var n: Int }

@inline(never) func inner() throws(ReadError) -> Int { throw ReadError(status: .wait, n: 0) }

func read() throws(Status) -> Int {
  var bytes = [UInt8](repeating: 0, count: 16)
  do {
    return try bytes.withUnsafeMutableBytes { (b) throws(ReadError) in try inner() }
  } catch {
    throw (error as? ReadError)?.status ?? .bad
  }
}

@main struct Repro {
  static func main() {
    var bad = 0
    for _ in 0..<1000 {
      do { _ = try read() } catch { if "\(error)" != "wait" || error != .wait { bad += 1 } }
    }
    print(bad == 0 ? "ok" : "CORRUPT \(bad)/1000")
  }
}
