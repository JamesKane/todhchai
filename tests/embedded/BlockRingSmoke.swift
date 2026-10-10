// SPDX-License-Identifier: BSD-3-Clause

// The block ring built as Embedded Swift on the host: both sides over plain
// memory, wrapping, the wakeup flags, and a client that breaks the rules.
// tests/block runs it through the service.

import BlockRing

@main struct BlockRingSmoke {
  static func main() {
    let entries = 4
    let size = BlockRing.size(entries: entries)
    let base = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
    defer { unsafe base.deallocate() }
    var server = RingServer(unsafe RingMemory(formatting: base, length: size, entries: entries))
    guard let memory = unsafe RingMemory(mapping: base, length: size) else { fatalError("layout") }
    var client = RingClient(memory)

    // Round trips, past the end of the ring several times.
    for round in 0..<10 {
      for i in 0..<3 {
        let tag = UInt64(round * 3 + i)
        check(client.submit(Submission(.read, tag: tag, block: tag, count: 1)), "submit")
      }
      _ = client.publish()
      var n: UInt64 = 0
      while let taken = try? server.take(), case .request(let s) = taken {
        check(s.tag == UInt64(round * 3) + n && s.block == s.tag && s.count == 1, "request")
        server.complete(Completion(tag: s.tag, status: .ok, count: 1))
        n += 1
      }
      check(n == 3, "took all")
      _ = server.publish()
      for i in 0..<3 {
        guard let c = client.reap() else { fatalError("reap") }
        check(c.tag == UInt64(round * 3 + i) && c.status == .ok, "completion")
      }
      check(client.reap() == nil, "drained")
    }

    // A full ring refuses more.
    for i in 0..<entries { check(client.submit(Submission(.flush, tag: UInt64(i))), "fill") }
    check(!client.submit(Submission(.flush, tag: 99)), "full")

    // The service idles, so publishing asks for a kick; then it doesn't.
    var idle = server
    while let _ = try? idle.take() {}
    check(!idle.prepareToIdle(), "nothing new yet")
    check(client.publish(), "kick the idle service")

    // A client that claims more than the ring holds is cut off.
    var corrupt = false
    unsafe base.storeBytes(of: UInt32(1000), toByteOffset: 64, as: UInt32.self)
    do throws(RingServer.Corrupt) { _ = try server.take() } catch { corrupt = true }
    check(corrupt, "corrupt")
    print("embedded BlockRing: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
