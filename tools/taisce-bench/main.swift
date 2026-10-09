// SPDX-License-Identifier: BSD-3-Clause

// taisce-bench: S0's and S1's budgets (docs/milestones/S0.md, S1.md,
// docs/performance.md), measured on the host from trace zones and
// counters, ahead of M3's QEMU numbers. In memory, so the file system and
// not a disk:
//
//   fs.read4k          open and read a cached 4 KiB file through the
//                      namespace: two lookups and a read (M3's target:
//                      5 µs, in QEMU), on the writer's thread
//   fs.live            a matching attribute write, then the live query's
//                      update that reports it (M3's target: 1 ms)
//   fs.read4k.reader   the same read by a lock-free reader thread (S1f)
//   fs.readers.ns.N    a reader's mean time per read with N threads
//                      reading at once (counters, N = 1 and 4)
//
// On a 1 GiB image file under .build (the host's disk, so its flushes):
//
//   fs.fsync           a 4 KiB write and fsync, through the intent log
//   fs.commit          a group of 64 writes and attributes committed
//
//   swift build -c release --product taisce-bench
//   .build/debug/td trace record -o DIR -- .build/release/taisce-bench

import Glibc
import Synchronization
import Taisce
import TaisceHost
import Trace

enum Names {
  static let read4k = TraceName("fs.read4k")
  static let live = TraceName("fs.live")
  static let readerRead4k = TraceName("fs.read4k.reader")
  static let fsync = TraceName("fs.fsync")
  static let commit = TraceName("fs.commit")
  static let readers1 = TraceName("fs.readers.ns.1")
  static let readers4 = TraceName("fs.readers.ns.4")
}

enum Readers {
  /// A cached 4 KiB read through the namespace, by a lock-free reader.
  static func read4k(_ r: inout FileReader<SharedMemoryDevice>, _ i: Int) throws(TaisceError) -> UInt8 {
    try r.withSnapshot { (r: inout FileReader<SharedMemoryDevice>) throws(TaisceError) -> UInt8 in
      let dir = try r.lookup(FileSystem<SharedMemoryDevice>.root, name("data"))
      return try r.read(try r.lookup(dir, name("file\(i)")), offset: 0, count: 4096)[i % 4096]
    }
  }
}

/// A reader thread's handover, and how many reads it managed.
final class ReaderRun: @unchecked Sendable {
  var reader: FileReader<SharedMemoryDevice>?
  let start = Atomic<Bool>(false), stop = Atomic<Bool>(false)
  let reads = Atomic<Int>(0)
  init(_ reader: consuming FileReader<SharedMemoryDevice>) { self.reader = consume reader }
}

func name(_ s: String) -> [UInt8] { Array(s.utf8) }

func nanoseconds() -> UInt64 {
  var t = timespec()
  clock_gettime(CLOCK_MONOTONIC, &t)
  return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

_ = Trace.startFromEnvironment()
do {
  var fs = try FileSystem.format(SharedMemoryDevice(blocks: 65_536), label: [], uuid: [UInt8](repeating: 7, count: 16),
                                 now: 1)
  let root = FileSystem<SharedMemoryDevice>.root
  let data = try fs.create(root, name("data"), .directory, mode: 0o755, now: 2)
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
    let dir = try fs.lookup(root, name("data"))
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

  // Lock-free readers (S1f): one reading alone, then 1 and 4 at once.
  try fs.sync()
  guard var reader = fs.reader() else { fatalError("no reader") }
  for i in 0..<1000 { _ = try Readers.read4k(&reader, i) }
  for k in 0..<5000 {
    let i = (k &* 7919) % 1000
    let start = Trace.now()
    sum &+= Int(try Readers.read4k(&reader, i))
    Trace.zone(Names.readerRead4k, .app, since: start)
  }
  _ = consume reader
  for threads in [1, 4] {
    var runs: [ReaderRun] = []
    var ids: [pthread_t] = []
    for _ in 0..<threads {
      guard let r = fs.reader() else { fatalError("no reader") }
      let run = ReaderRun(r)
      runs.append(run)
      ids.append(ToolSupport.spawn {
        var r = run.reader.take()!
        for i in 0..<1000 { _ = try? Readers.read4k(&r, i) }  // warm this thread's caches
        while !run.start.load(ordering: .acquiring) {}
        var k = 0
        while !run.stop.load(ordering: .relaxed) {
          _ = try? Readers.read4k(&r, (k &* 7919) % 1000)
          k += 1
        }
        run.reads.store(k, ordering: .releasing)
      })
    }
    usleep(200_000)  // every thread warm
    let t0 = nanoseconds()
    for run in runs { run.start.store(true, ordering: .releasing) }
    usleep(500_000)
    for run in runs { run.stop.store(true, ordering: .relaxed) }
    let t1 = nanoseconds()
    for id in ids { ToolSupport.join(id) }
    let reads = runs.reduce(0) { $0 + $1.reads.load(ordering: .acquiring) }
    // Mean time per read, per thread: wall time × threads ÷ reads.
    let ns = Int64(Double(t1 - t0) * Double(threads) / Double(max(reads, 1)))
    Trace.counter(threads == 1 ? Names.readers1 : Names.readers4, ns)
  }

  // On the disk: fsync through the intent log, and group commits.
  let image = ".build/taisce-bench.img"
  defer { unlink(image) }
  var disk = try FileSystem.format(FileDevice(path: image, blocks: 262_144), label: [], uuid: [UInt8](repeating: 9, count: 16),
                                   now: 1)
  var onDisk: [UInt64] = []
  for i in 0..<64 {
    let f = try disk.create(root, name("f\(i)"), .file, mode: 0o644, now: 2)
    try disk.write(f, offset: 0, page, now: 2)
    onDisk.append(f)
  }
  try disk.sync()
  for k in 0..<300 {
    let start = Trace.now()
    try disk.write(onDisk[k % 64], offset: UInt64(k % 16) * 4096, page, now: 3)
    try disk.fsync()
    Trace.zone(Names.fsync, .app, since: start)
  }
  try disk.sync()
  for round in 0..<60 {
    for (i, f) in onDisk.enumerated() {
      try disk.write(f, offset: 0, page, now: 4)
      if i % 4 == 0 { try disk.setAttribute(f, name("user:round"), .int64(Int64(round)), now: 4) }
    }
    let start = Trace.now()
    try disk.sync()
    Trace.zone(Names.commit, .app, since: start)
  }
  print("taisce-bench: done (\(sum))")
} catch {
  print("taisce-bench: \(error)")
}
