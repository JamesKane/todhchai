// SPDX-License-Identifier: BSD-3-Clause

// taisce-bench: S0's budgets (docs/milestones/S0.md, docs/performance.md),
// measured on the host from trace zones, ahead of M3's QEMU numbers. The
// volume is in memory, so this is the file system, not a disk:
//
//   fs.read4k  open and read a cached 4 KiB file through the namespace:
//              two lookups and a read (M3's target: 5 µs, in QEMU)
//   fs.live    a matching attribute write, then the live query's update
//              that reports it (M3's target: 1 ms)
//
//   swift build -c release --product taisce-bench
//   .build/debug/td trace record -o DIR -- .build/release/taisce-bench

import Taisce
import Trace

enum Names {
  static let read4k = TraceName("fs.read4k")
  static let live = TraceName("fs.live")
}

func name(_ s: String) -> [UInt8] { Array(s.utf8) }

_ = Trace.startFromEnvironment()
do {
  var fs = try FileSystem.format(MemoryDevice(blocks: 65_536), label: [], uuid: [UInt8](repeating: 7, count: 16), now: 1)
  let data = try fs.create(FileSystem<MemoryDevice>.root, name("data"), .directory, mode: 0o755, now: 2)
  let page = (0..<4096).map { UInt8(truncatingIfNeeded: $0) }
  var files: [UInt64] = []
  for i in 0..<1000 {
    let f = try fs.create(data, name("file\(i)"), .file, mode: 0o644, now: 3)
    try fs.write(f, offset: 0, page, now: 3)
    files.append(f)
  }
  try fs.sync()
  // Warm: every node read once, as a cache would hold them.
  for i in 0..<1000 { _ = try fs.read(try fs.lookup(data, name("file\(i)")), offset: 0, count: 4096) }

  var sum = 0
  for k in 0..<5000 {
    let i = (k &* 7919) % 1000
    let start = Trace.now()
    let dir = try fs.lookup(FileSystem<MemoryDevice>.root, name("data"))
    let bytes = try fs.read(try fs.lookup(dir, name("file\(i)")), offset: 0, count: 4096)
    Trace.zone(Names.read4k, .app, since: start)
    sum &+= Int(bytes[i % 4096])
  }

  try fs.declareIndex(name("user:tag"), .string)
  while try !fs.backfill(budget: 1000) {}
  var live = try fs.live(name(#"user:tag == "hit""#))
  for k in 0..<2000 {
    let f = files[(k &* 31) % 1000]
    let start = Trace.now()
    try fs.setAttribute(f, name("user:tag"), .string(name("hit")), now: 4)
    let updates = try fs.update(&live)
    Trace.zone(Names.live, .app, since: start)
    guard updates.contains(where: { if case .added(f, _) = $0 { true } else { false } }) else {
      print("taisce-bench: the live query missed a write")
      break
    }
    _ = try fs.removeAttribute(f, name("user:tag"), now: 5)
    _ = try fs.update(&live)
    if k % 200 == 0 { try fs.sync() }
  }
  print("taisce-bench: done (\(sum))")
} catch {
  print("taisce-bench: \(error)")
}
