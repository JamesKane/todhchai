// SPDX-License-Identifier: BSD-3-Clause

import FoundationEssentials
import Glibc
import Testing
import Wayland
import WaylandGen

let root: String = {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/wayland/WaylandTests.swift
  return parts.joined(separator: "/")
}()

let protocolFiles = ["wayland.xml", "xdg-shell.xml", "presentation-time.xml", "viewporter.xml", "fractional-scale-v1.xml"]

// MARK: XML and generation

@Test func xmlReaderHandlesWhatProtocolsUse() throws {
  let e = try parseXML("""
    <?xml version="1.0"?>
    <!-- a comment -->
    <protocol name="p &amp; q">
      <interface name='i' version="2"><request name="r"/></interface>
      <copyright>&lt;&#65;&#x42;&gt;</copyright>
    </protocol>
    """)
  #expect(e.name == "protocol" && e.attribute("name") == "p & q")
  #expect(e.elements("interface").first?.elements("request").first?.attribute("name") == "r")
  #expect(e.elements("copyright").first?.text == "<AB>")
  #expect(throws: XMLError.self) { try parseXML("<a><b></a>") }
  #expect(throws: XMLError.self) { try parseXML("<a x=1/>") }
}

@Test func generatedCodeIsInStepWithTheXML() throws {
  let protocols = try protocolFiles.map { try readProtocol(try String(contentsOfFile: "\(root)/data/wayland/\($0)", encoding: .utf8)) }
  let fresh = SwiftGenerator(protocols).generate(sources: protocolFiles)
  let checkedIn = try String(contentsOfFile: "\(root)/lib/wayland/generated/Protocols.swift", encoding: .utf8)
  #expect(fresh == checkedIn, "regenerate: wlgen lib/wayland/generated/Protocols.swift data/wayland/*.xml (CLAUDE.md)")
  #expect(protocols[0].interfaces.count == 23)
}

// MARK: A scripted compositor over a socketpair

/// The compositor's end: raw bytes and fds in, scripted events out.
struct FakeCompositor {
  let fd: Int32

  /// Sends an event: object, opcode, argument words.
  func event(_ object: UInt32, _ opcode: UInt16, _ args: [UInt32], fds: [Int32] = []) {
    var words = [object, UInt32(8 + 4 * args.count) << 16 | UInt32(opcode)] + args
    var control = [UInt8](repeating: 0, count: 64)
    words.withUnsafeMutableBytes { data in
      control.withUnsafeMutableBytes { ctl in
        var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
        withUnsafeMutablePointer(to: &iov) { iovp in
          var msg = msghdr()
          msg.msg_iov = iovp
          msg.msg_iovlen = 1
          if !fds.isEmpty {
            let len = MemoryLayout<cmsghdr>.size + 4 * fds.count
            let header = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = len
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = Int32(SCM_RIGHTS)
            fds.withUnsafeBytes { (ctl.baseAddress! + MemoryLayout<cmsghdr>.size).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            msg.msg_control = ctl.baseAddress
            msg.msg_controllen = (len + 7) & ~7
          }
          _ = sendmsg(fd, &msg, 0)
        }
      }
    }
  }

  /// What the client sent: words, and any fds.
  func read() -> ([UInt32], [Int32]) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    var control = [UInt8](repeating: 0, count: 256)
    var fds: [Int32] = []
    let n: Int = buffer.withUnsafeMutableBytes { data in
      control.withUnsafeMutableBytes { ctl in
        var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
        return withUnsafeMutablePointer(to: &iov) { iovp in
          var msg = msghdr()
          msg.msg_iov = iovp
          msg.msg_iovlen = 1
          msg.msg_control = ctl.baseAddress
          msg.msg_controllen = ctl.count
          let r = recvmsg(fd, &msg, 0)
          if msg.msg_controllen > 0 {
            let h = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self).pointee
            for k in 0..<((Int(h.cmsg_len) - MemoryLayout<cmsghdr>.size) / 4) {
              fds.append((ctl.baseAddress! + MemoryLayout<cmsghdr>.size).loadUnaligned(fromByteOffset: 4 * k, as: Int32.self))
            }
          }
          return r
        }
      }
    }
    let words = buffer[..<max(n, 0)].withUnsafeBytes { raw in (0..<(max(n, 0) / 4)).map { raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self) } }
    return (words, fds)
  }
}

func pair() -> (WaylandConnection, FakeCompositor) {
  var fds: [Int32] = [0, 0]
  socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
  return (WaylandConnection(fd: fds[0]), FakeCompositor(fd: fds[1]))
}

/// "xdg_wm_base" as wire words: length with NUL, bytes, padding.
func wireString(_ s: String) -> [UInt32] {
  var m = WaylandMessage()
  m.string(s)
  return messageWords(m)
}

func messageWords(_ m: WaylandMessage) -> [UInt32] {
  // WaylandMessage's words are internal; rebuild them through a request.
  let (c, fake) = pair()
  c.send(9, 0) { $0 = m }
  try? c.flush()
  return Array(fake.read().0.dropFirst(2))
}

@Test func requestsEncodeAsTheWireFormatSays() throws {
  let (c, fake) = pair()
  let registry = c.display.getRegistry(c)
  let compositor = registry.bind(c, WlCompositor.self, version: 6, name: 7)
  try c.flush()
  let (words, _) = fake.read()
  // wl_display.get_registry(new id 2), then wl_registry.bind(name 7, "wl_compositor", 6, new id 3).
  let name = Array("wl_compositor".utf8) + [0, 0, 0]  // 13 bytes + NUL, padded to 16
  var nameWords: [UInt32] = []
  for i in stride(from: 0, to: 16, by: 4) {
    let low = UInt32(name[i]) | UInt32(name[i + 1]) << 8
    let high = UInt32(name[i + 2]) << 16 | UInt32(name[i + 3]) << 24
    nameWords.append(low | high)
  }
  #expect(words == [1, 12 << 16 | 1, 2] + [2, UInt32(8 + 4 * 8) << 16 | 0, 7, 14] + nameWords + [6, 3])
  #expect(registry.id == 2 && compositor.id == 3)
}

@Test func eventsDecodeTyped() throws {
  let (c, fake) = pair()
  let registry = c.display.getRegistry(c)
  try c.flush()
  _ = fake.read()
  fake.event(registry.id, 0, [42] + wireString("xdg_wm_base") + [7])  // global(name, interface, version)
  var events: [WaylandEvent] = []
  while events.isEmpty { events = try c.receive() }
  guard case .wlRegistry(let r, .global(let name, let interface, let version)) = events.first else {
    Issue.record("expected a global, got \(events)")
    return
  }
  #expect(r == registry && name == 42 && interface == "xdg_wm_base" && version == 7)
}

@Test func fileDescriptorsTravelBothWays() throws {
  let (c, fake) = pair()
  let shm = c.newObject(WlShm.self, version: 1)
  let memfd = open("/dev/null", O_RDONLY)
  _ = shm.createPool(c, fd: memfd, size: 4096)
  try c.flush()
  let (words, fds) = fake.read()
  #expect(words.count == 4 && fds.count == 1)  // header 2, new id, size; the fd out of band
  for fd in fds { close(fd) }
  close(memfd)

  // wl_keyboard.keymap(format, fd, size) carries one the other way.
  let keyboard = c.newObject(WlKeyboard.self, version: 1)
  var pipeFDs: [Int32] = [0, 0]
  pipe(&pipeFDs)
  fake.event(keyboard.id, 0, [1, 4096], fds: [pipeFDs[0]])
  var events: [WaylandEvent] = []
  while events.isEmpty { events = try c.receive() }
  guard case .wlKeyboard(_, .keymap(_, let fd, let size)) = events.first else {
    Issue.record("expected a keymap")
    return
  }
  #expect(fd >= 0 && size == 4096)
  close(fd)
  close(pipeFDs[0])
  close(pipeFDs[1])
}

@Test func protocolErrorsAndDeleteIDsAreHandled() throws {
  let (c, fake) = pair()
  let callback = c.display.sync(c)
  try c.flush()
  _ = fake.read()
  fake.event(1, 1, [callback.id])  // wl_display.delete_id
  _ = try c.receive()
  fake.event(callback.id, 0, [5])  // a late event for the deleted object is skipped
  #expect(try c.receive().isEmpty)
  fake.event(1, 0, [3, 2] + wireString("bad request"))  // wl_display.error
  #expect(throws: WaylandError.protocolError(object: 3, code: 2, message: "bad request")) { _ = try c.receive() }
}

// MARK: The live compositor

/// Talks to the desktop's compositor without showing anything: lists its
/// globals and does a round trip. Skipped where there is no compositor.
@Test(.enabled(if: getenv("WAYLAND_DISPLAY") != nil)) func liveCompositorHasWhatWeNeed() throws {
  let c = try WaylandConnection()
  let registry = c.display.getRegistry(c)
  let done = c.display.sync(c)
  try c.flush()
  var globals: [String: UInt32] = [:]
  var finished = false
  var pfd = pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)
  while !finished {
    guard poll(&pfd, 1, 2000) == 1 else { Issue.record("no reply from the compositor in 2 s"); return }
    for e in try c.receive() {
      switch e {
      case .wlRegistry(registry, .global(_, let interface, let version)): globals[interface] = version
      case .wlCallback(done, .done): finished = true
      default: break
      }
    }
  }
  for needed in ["wl_compositor", "wl_shm", "xdg_wm_base", "wl_seat", "wp_presentation", "wp_viewporter"] {
    #expect(globals[needed] != nil, "the compositor has no \(needed)")
  }
}
