// SPDX-License-Identifier: BSD-3-Clause

// S0's exit (docs/milestones/S0.md), through a real FUSE mount: a Taisce
// image mounts on the desktop, files written there carry typed attributes,
// a declared index answers a query, and a live query reports the write.
// The server runs in this process on a thread; the test uses the mount
// with ordinary system calls, as any program would. It mounts, so it runs
// only with TODHCHAI_LIVE_FUSE=1. (The crash harness, shadow-model fuzzer
// and query fuzzer, the rest of the exit, run in td ci.)

import FuseLayoutC
import Glibc
import Taisce
@testable import TaisceHost
import Testing

/// Runs `body` on a new thread.
final class Background: @unchecked Sendable {
  let body: () -> Void
  var thread = pthread_t()
  init(_ body: @escaping () -> Void) {
    self.body = body
    let me = Unmanaged.passRetained(self).toOpaque()
    pthread_create(&thread, nil, { arg in
      Unmanaged<Background>.fromOpaque(arg!).takeRetainedValue().body()
      return nil
    }, me)
  }
  func join() { pthread_join(thread, nil) }
}

func put(_ path: String, _ text: String) -> Bool {
  let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  let b = Array(text.utf8)
  return b.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == b.count
}

func get(_ path: String) -> String? {
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = chunk.withUnsafeMutableBytes({ read(fd, $0.baseAddress, 4096) }), n > 0 { out += chunk[..<n] }
  return String(decoding: out, as: UTF8.self)
}

@Test(.enabled(if: getenv("TODHCHAI_LIVE_FUSE") != nil))
func s0ExitThroughAFuseMount() throws {
  let dir = "/tmp/taisce-exit-\(getpid())"
  let image = dir + ".img", mnt = dir + "/mnt"
  mkdir(dir, 0o755)
  mkdir(mnt, 0o755)
  defer {
    unlink(image)
    rmdir(mnt)
    rmdir(dir)
  }
  // mkfs, then serve it.
  var made = try FileSystem.format(FileDevice(path: image, blocks: 16_384), label: Array("exit".utf8),
                                   uuid: ToolSupport.uuid(), now: ToolSupport.now)
  try made.setAttributes(1, uid: getuid(), gid: getgid(), now: ToolSupport.now)
  try made.sync()
  _ = consume made
  let server = FuseServer(try FileSystem.mount(FileDevice(path: image)), fd: try FuseMount.mount(mnt, name: image))
  server.startReaders(4)
  let serving = Background { server.serve() }
  var unmounted = false
  defer { if !unmounted { FuseMount.unmount(mnt); serving.join() } }

  // Files with typed attributes.
  #expect(mkdir(mnt + "/music", 0o755) == 0)
  for (name, year) in [("a.mp3", 1993), ("b.mp3", 1985), ("c.mp3", 2004)] {
    #expect(put("\(mnt)/music/\(name)", "song \(name)"))
    let value = Array("int64:\(year)".utf8)
    #expect(fuse_test_setxattr("\(mnt)/music/\(name)", "user.Audio:Year", value, value.count) == 0)
  }
  var buffer = [UInt8](repeating: 0, count: 64)
  let n = fuse_test_getxattr("\(mnt)/music/a.mp3", "user.Audio:Year", &buffer, 64)
  #expect(n > 0 && String(decoding: buffer[..<n], as: UTF8.self) == "int64:1993")

  // A declared index answers a query.
  #expect(put(mnt + "/.taisce/index", "Audio:Year int64\n"))
  #expect(get(mnt + "/.taisce/index")?.contains("Audio:Year int64") == true)
  #expect(put(mnt + "/.taisce/query", "Audio:Year > 1990 order by Audio:Year\n"))
  #expect(get(mnt + "/.taisce/query") == "/music/a.mp3\n/music/c.mp3\n")

  // A live query reports the write: a reader blocked on the live file
  // wakes with the new match.
  #expect(put(mnt + "/.taisce/live", "Audio:Year >= 2000\n"))
  let live = open(mnt + "/.taisce/live", O_RDONLY)
  #expect(live >= 0)
  var first = [UInt8](repeating: 0, count: 4096)
  let initial = first.withUnsafeMutableBytes { read(live, $0.baseAddress, 4096) }
  #expect(initial > 0 && String(decoding: first[..<initial], as: UTF8.self) == "+ /music/c.mp3\n")
  final class Got: @unchecked Sendable { var text = "" }
  let got = Got()
  let reader = Background {
    var b = [UInt8](repeating: 0, count: 4096)
    let k = b.withUnsafeMutableBytes { read(live, $0.baseAddress, 4096) }
    if k > 0 { got.text = String(decoding: b[..<k], as: UTF8.self) }
  }
  usleep(200_000)  // the reader is blocked in the kernel by now
  #expect(got.text.isEmpty)
  #expect(put(mnt + "/music/d.mp3", "new song"))
  let value = Array("int64:2026".utf8)
  #expect(fuse_test_setxattr(mnt + "/music/d.mp3", "user.Audio:Year", value, value.count) == 0)
  reader.join()
  #expect(got.text == "+ /music/d.mp3\n")
  close(live)

  // Unmounted, the image is clean and keeps it all.
  FuseMount.unmount(mnt)
  serving.join()
  unmounted = true
  var after = try FileSystem.mount(FileDevice(path: image))
  try after.check()
  #expect(try after.query(Array("Audio:Year >= 1985".utf8)).count == 4)
}
