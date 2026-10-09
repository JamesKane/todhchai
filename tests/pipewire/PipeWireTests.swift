// SPDX-License-Identifier: BSD-3-Clause

import Glibc
import PipeWire
import Testing

func words(_ bytes: [UInt8]) -> [UInt32] {
  stride(from: 0, to: bytes.count, by: 4).map { i in
    let a = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
    return a | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
  }
}

/// The Hello payload: docs/research/pipewire-protocol.md §1.2.
@Test func helloPayloadMatchesTheSpec() {
  var w = PodWriter()
  w.write(.struct([.int(4)]))
  #expect(words(w.bytes) == [0x10, 0x0e, 0x04, 0x04, 0x04, 0x00])
}

/// The Buffers param measured from PipeWire 1.6.9's own builder (§2.5).
@Test func buffersParamMatchesTheMeasuredBytes() {
  var w = PodWriter()
  w.write(.object(type: 0x40004, id: 5, [Pod.Property(1, .choice(type: 1, [.int(2), .int(1), .int(8)]))]))
  #expect(words(w.bytes) == [0x38, 0x0f, 0x40004, 0x05, 0x01, 0x00, 0x1c, 0x13, 0x01, 0x00, 0x04, 0x04, 0x02, 0x01, 0x08, 0x00])
}

@Test func arraysOfIdsMatchTheSpec() {
  var w = PodWriter()
  w.write(.struct([.array(childType: 3, [.id(3), .id(4)])]))
  #expect(words(w.bytes) == [0x18, 0x0e, 0x10, 0x0d, 0x04, 0x03, 0x03, 0x04])
}

@Test func podsRoundTrip() throws {
  let pod: Pod = .struct([
    .none, .bool(true), .id(7), .int(-3), .long(1 << 40), .float(0.5), .double(-2.25), .string("pipewire"),
    .bytes([1, 2, 3]), .fraction(1, 48000), .fd(2),
    .object(type: 0x40003, id: 4, [Pod.Property(1, .id(1)), Pod.Property(0x10005, .array(childType: 3, [.id(3), .id(4)]))]),
    .choice(type: 3, [.int(2), .int(1), .int(2)]),
  ])
  var w = PodWriter()
  w.write(pod)
  let (back, end) = try readPod(w.bytes[...], at: 0)
  #expect(end == w.bytes.count)
  if case .struct(let a) = pod, case .struct(let b) = back {
    #expect(a.count == b.count)
    for (x, y) in zip(a, b) { #expect(x == y) }
  }
  #expect(throws: PodError.truncated) { try readPod(w.bytes.prefix(12), at: 0) }
}

/// Plays silence through the desktop's PipeWire for a second and checks
/// the graph drives the node. Runs only with TODHCHAI_LIVE_AUDIO=1.
@Test(.enabled(if: getenv("TODHCHAI_LIVE_AUDIO") != nil))
func theGraphDrivesOurNode() throws {
  let p = try PipeWirePlayback(PlaybackOptions(name: "todhchai-test"))
  let start = clock()
  var fds = [pollfd(fd: p.socketFD, events: Int16(POLLIN), revents: 0), pollfd(fd: p.readFD, events: Int16(POLLIN), revents: 0)]
  var rendered = 0
  let until = Deadline.after(seconds: 1)
  while Deadline.now() < until {
    guard poll(&fds, 2, 100) > 0 else { continue }
    if fds[0].revents != 0 { try p.handleSocket() }
    if fds[1].revents != 0 { p.cycle { out in rendered += out.count; out.update(repeating: 0) } }
  }
  _ = start
  // About 48000 / quantum cycles a second; the quantum may differ from 128.
  let expected = 48_000 / p.quantum
  #expect(p.cycles > expected / 2, "\(p.cycles) cycles at quantum \(p.quantum)")
  #expect(rendered == p.cycles * p.quantum * 2 || rendered > 0)
}

enum Deadline {
  static func now() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
  }
  static func after(seconds: UInt64) -> UInt64 { now() + seconds * 1_000_000_000 }
}
