// SPDX-License-Identifier: BSD-3-Clause

// A connection to a Wayland compositor: the socket, an object table, and
// buffered sending (requests are encoded as they are made and sent by
// `flush`). Spoken directly, with no libwayland (architecture §18).

import Glibc

public final class WaylandConnection {
  public let fd: Int32
  var objects: [UInt32: (interface: WaylandInterface, version: UInt32)] = [:]
  var nextID: UInt32 = 2  // 1 is wl_display
  var out: [UInt32] = []
  var outFDs: [Int32] = []
  var inBytes: [UInt8] = []
  var receivedFDs: [Int32] = []

  /// The display, object 1.
  public let display = WlDisplay(id: 1)

  /// Connects to the compositor named by $WAYLAND_DISPLAY (a socket name in
  /// $XDG_RUNTIME_DIR, or an absolute path).
  public convenience init() throws(WaylandError) {
    guard let name = getenv("WAYLAND_DISPLAY").map({ String(cString: $0) }), !name.isEmpty else {
      throw .noDisplay
    }
    let path: String
    if name.hasPrefix("/") {
      path = name
    } else {
      guard let dir = getenv("XDG_RUNTIME_DIR").map({ String(cString: $0) }) else { throw .noDisplay }
      path = "\(dir)/\(name)"
    }
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { throw .system(errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw .noDisplay
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let ok = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else {
      close(fd)
      throw .noDisplay
    }
    self.init(fd: fd)
  }

  /// Uses an already-connected socket (tests use a socketpair).
  public init(fd: Int32) {
    self.fd = fd
    objects[1] = (.wlDisplay, 1)
  }

  deinit {
    close(fd)
    for fd in receivedFDs { close(fd) }
  }

  // MARK: Objects

  /// A new client-side object of type T at `version`.
  public func newObject<T: WaylandObject>(_: T.Type, version: UInt32) -> T {
    let id = nextID
    nextID += 1
    objects[id] = (T.interface, version)
    return T(id: id)
  }

  public func register(_ id: UInt32, _ interface: WaylandInterface, version: UInt32) {
    objects[id] = (interface, version)
  }

  /// Forgets an object (after its destructor request, or delete_id).
  public func forget(_ id: UInt32) { objects[id] = nil }

  public func version(of id: UInt32) -> UInt32 { objects[id]?.version ?? 1 }

  // MARK: Sending

  /// Encodes a request onto the send buffer.
  public func send(_ object: UInt32, _ opcode: Int, _ build: (inout WaylandMessage) -> Void) {
    var m = WaylandMessage()
    build(&m)
    let size = UInt32(8 + 4 * m.words.count)
    out.append(object)
    out.append(size << 16 | UInt32(opcode))
    out.append(contentsOf: m.words)
    outFDs.append(contentsOf: m.fds)
  }

  /// Sends what's buffered. File descriptors go with the first bytes, at
  /// most 28 per message (libwayland's limit, which compositors expect).
  public func flush() throws(WaylandError) {
    var bytes = out.withUnsafeBytes { Array($0) }
    out.removeAll(keepingCapacity: true)
    var fds = outFDs
    outFDs.removeAll()
    while !bytes.isEmpty || !fds.isEmpty {
      let batch = Array(fds.prefix(28))
      fds.removeFirst(batch.count)
      let sent = try sendmsg(bytes, fds: batch)
      bytes.removeFirst(sent)
      if bytes.isEmpty && !fds.isEmpty { throw .system(EINVAL) }  // fds with no bytes to carry them
    }
  }

  func sendmsg(_ bytes: [UInt8], fds: [Int32]) throws(WaylandError) -> Int {
    let control = cmsgSpace(fds.count)
    var controlBuffer = [UInt8](repeating: 0, count: control)
    var bytes = bytes
    let result: Int = bytes.withUnsafeMutableBytes { data in
      controlBuffer.withUnsafeMutableBytes { ctl in
        var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
        return withUnsafeMutablePointer(to: &iov) { iovp in
          var msg = msghdr()
          msg.msg_iov = iovp
          msg.msg_iovlen = 1
          if !fds.isEmpty {
            msg.msg_control = ctl.baseAddress
            msg.msg_controllen = control
            let header = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = cmsgLength(fds.count)
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = Int32(SCM_RIGHTS)
            let payload = ctl.baseAddress! + MemoryLayout<cmsghdr>.size
            fds.withUnsafeBytes { payload.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
          }
          var r: Int
          repeat { r = Glibc.sendmsg(self.fd, &msg, Int32(MSG_NOSIGNAL)) } while r < 0 && errno == EINTR
          return r
        }
      }
    }
    guard result >= 0 else { throw errno == EPIPE ? .closed : .system(errno) }
    return result
  }

  func cmsgLength(_ fdCount: Int) -> Int { MemoryLayout<cmsghdr>.size + fdCount * 4 }
  func cmsgSpace(_ fdCount: Int) -> Int { (cmsgLength(fdCount) + 7) & ~7 }

  // MARK: Receiving

  /// Reads what the socket has and decodes every complete message. Call
  /// when the socket is readable; it doesn't block.
  public func receive() throws(WaylandError) -> [WaylandEvent] {
    var buffer = [UInt8](repeating: 0, count: 4096)
    var control = [UInt8](repeating: 0, count: cmsgSpace(28))
    let n: Int = buffer.withUnsafeMutableBytes { data in
      control.withUnsafeMutableBytes { ctl in
        var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
        return withUnsafeMutablePointer(to: &iov) { iovp in
          var msg = msghdr()
          msg.msg_iov = iovp
          msg.msg_iovlen = 1
          msg.msg_control = ctl.baseAddress
          msg.msg_controllen = ctl.count
          var r: Int
          repeat { r = recvmsg(self.fd, &msg, Int32(MSG_DONTWAIT | MSG_CMSG_CLOEXEC)) } while r < 0 && errno == EINTR
          if r > 0 && msg.msg_controllen >= MemoryLayout<cmsghdr>.size {
            let header = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self).pointee
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == Int32(SCM_RIGHTS) {
              let count = (Int(header.cmsg_len) - MemoryLayout<cmsghdr>.size) / 4
              let payload = ctl.baseAddress! + MemoryLayout<cmsghdr>.size
              for k in 0..<count { self.receivedFDs.append(payload.loadUnaligned(fromByteOffset: 4 * k, as: Int32.self)) }
            }
          }
          return r
        }
      }
    }
    if n == 0 { throw .closed }
    if n < 0 {
      if errno == EAGAIN || errno == EWOULDBLOCK { return [] }
      throw .system(errno)
    }
    inBytes.append(contentsOf: buffer[..<n])
    return try decodeBuffered()
  }

  /// Decodes every complete message in the input buffer.
  func decodeBuffered() throws(WaylandError) -> [WaylandEvent] {
    var events: [WaylandEvent] = []
    var at = 0
    while inBytes.count - at >= 8 {
      let words: [UInt32] = inBytes[at..<(at + 8)].withUnsafeBytes { [$0.loadUnaligned(as: UInt32.self), $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)] }
      let object = words[0], size = Int(words[1] >> 16), opcode = UInt16(words[1] & 0xffff)
      guard size >= 8, size % 4 == 0 else { throw .truncated }
      guard inBytes.count - at >= size else { break }
      let argWords: [UInt32] = inBytes[(at + 8)..<(at + size)].withUnsafeBytes { raw in
        (0..<((size - 8) / 4)).map { raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self) }
      }
      at += size
      guard let known = objects[object] else {
        // Events for an object we destroyed can still be in flight; skip them.
        continue
      }
      var reader = WaylandReader(argWords[...], self)
      let event = try decodeWaylandEvent(known.interface, id: object, opcode: opcode, &reader, self)
      if case .wlDisplay(_, let e) = event {
        switch e {
        case .error(let objectID, let code, let message):
          throw .protocolError(object: objectID, code: code, message: message)
        case .deleteId(let id):
          forget(id)
        }
      }
      events.append(event)
    }
    inBytes.removeFirst(at)
    return events
  }
}
