// SPDX-License-Identifier: BSD-3-Clause

// S1's exit (docs/milestones/S1.md), through a real FUSE mount served with
// reader threads: what a program fsyncs survives a crash before any group
// commit, through the intent log; and programs read while another writes,
// answered by the lock-free reader threads, without a failure. Runs only
// with TODHCHAI_LIVE_FUSE=1. (Checksums, corruption, the crash harness,
// the fuzzers and the readers' concurrency test run in td ci.)

import FuseLayoutC
import Glibc
import Synchronization
import Taisce
@testable import TaisceHost
import Testing

/// Writes `bytes` at the start of `path` (no truncation), then fsyncs.
func overwrite(_ path: String, _ bytes: [UInt8], fsync sync: Bool) -> Bool {
  let fd = open(path, O_WRONLY | O_CREAT, 0o644)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return false }
  return !sync || fsync(fd) == 0
}

func contents(_ path: String) -> [UInt8]? {
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65_536)
  while case let n = chunk.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }), n > 0 { out += chunk[..<n] }
  return out
}

final class MountReaders: Sendable {
  let stop = Atomic<Bool>(false)
  let reads = Atomic<Int>(0)
  let failed = Atomic<Int>(0)
}

@Test(.enabled(if: getenv("TODHCHAI_LIVE_FUSE") != nil))
func s1ExitThroughAFuseMount() throws {
  let dir = "/tmp/taisce-s1-exit-\(getpid())"
  let image = dir + ".img", crashed = dir + ".crashed.img", mnt = dir + "/mnt"
  mkdir(dir, 0o755)
  mkdir(mnt, 0o755)
  defer {
    unlink(image)
    unlink(crashed)
    rmdir(mnt)
    rmdir(dir)
  }
  var made = try FileSystem.format(FileDevice(path: image, blocks: 16_384), label: Array("s1".utf8),
                                   uuid: ToolSupport.uuid(), now: ToolSupport.now)
  try made.setAttributes(1, uid: getuid(), gid: getgid(), now: ToolSupport.now)
  try made.sync()
  _ = consume made
  let fs = try FileSystem.mount(FileDevice(path: image))
  let committed = fs.engine.store.volume.superblock.txg
  let server = FuseServer(fs, fd: try FuseMount.mount(mnt, name: image))
  server.startReaders(4)
  let serving = Background { server.serve() }
  var unmounted = false
  defer { if !unmounted { FuseMount.unmount(mnt); serving.join() } }

  // Programs read while another writes. Whether a read sees one write
  // whole isn't checked here: the kernel's page cache copies a page out
  // while a write copies into it, so reads tear at 64-byte steps below
  // the server. The server returns only blocks that match their
  // checksums, and ReaderTests checks whole versions beneath the kernel.
  let page = 16_384
  for f in 0..<4 { #expect(overwrite("\(mnt)/f\(f)", [UInt8](repeating: 0x41, count: page), fsync: false)) }
  let run = MountReaders()
  var readers: [Background] = []
  for t in 0..<4 {
    readers.append(Background {
      var k = t
      while !run.stop.load(ordering: .relaxed) {
        if contents("\(mnt)/f\(k % 4)")?.count != page { run.failed.add(1, ordering: .relaxed) }
        run.reads.add(1, ordering: .relaxed)
        k += 1
      }
    })
  }
  for v in 0..<300 {
    #expect(overwrite("\(mnt)/f\(v % 4)", [UInt8](repeating: 0x42 + UInt8(v % 20), count: page), fsync: false))
  }
  run.stop.store(true, ordering: .relaxed)
  for r in readers { r.join() }
  #expect(run.failed.load(ordering: .relaxed) == 0)
  #expect(run.reads.load(ordering: .relaxed) > 100)
  #expect(server.queue!.answered.load(ordering: .relaxed) > 0, "the reader threads answered requests")

  // fsync, then a crash: the image as it is now, before any group commit.
  #expect(overwrite("\(mnt)/promised", Array("fsynced through the intent log".utf8), fsync: false))
  let value = Array("int64:7".utf8)
  #expect(fuse_test_setxattr("\(mnt)/promised", "user.s1:x", value, value.count) == 0)
  #expect(overwrite("\(mnt)/promised", Array("fsynced through the intent log".utf8), fsync: true))
  guard let bytes = contents(image) else { Issue.record("can't read the image"); return }
  let fd = open(crashed, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  #expect(bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count)
  close(fd)

  FuseMount.unmount(mnt)
  serving.join()
  unmounted = true

  var device = try FileDevice(path: crashed)
  #expect(try Volume.newestSuperblock(&device).txg == committed, "no group committed: the log carried it")
  var after = try FileSystem.mount(FileDevice(path: crashed))
  let ino = try after.lookup(1, Array("promised".utf8))
  #expect(try after.read(ino, offset: 0, count: 100) == Array("fsynced through the intent log".utf8))
  #expect(try after.attribute(ino, Array("s1:x".utf8)) == .int64(7))
  try after.check()
}
