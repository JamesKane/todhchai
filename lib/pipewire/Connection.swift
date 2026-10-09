// SPDX-License-Identifier: BSD-3-Clause

// A connection to PipeWire (docs/research/pipewire-protocol.md §1): 16-byte
// headers (id, opcode << 24 | size, seq, n_fds), a Struct POD payload, and
// file descriptors as SCM_RIGHTS, kept in a FIFO independent of message
// boundaries.

import Glibc

public enum PipeWireError: Error, Equatable {
  case noServer
  case system(Int32)
  case closed
  case protocolError(String)
  /// Core::Error from the server: object, errno (negative), message.
  case server(id: UInt32, res: Int32, message: String)
}

/// A received message.
public struct PipeWireMessage {
  public var id: UInt32
  public var opcode: UInt8
  public var fields: [Pod]
  public var fds: [Int32]

  /// The fd a field's Fd index names, or -1.
  public func fd(_ field: Int) -> Int32 {
    guard field < fields.count, let i = fields[field].fd, i >= 0, i < Int64(fds.count) else { return -1 }
    return fds[Int(i)]
  }
}

public final class PipeWireConnection {
  public let fd: Int32
  var seq: UInt32 = 0
  var inBytes: [UInt8] = []
  var fdQueue: [Int32] = []

  /// Connects to $PIPEWIRE_RUNTIME_DIR or $XDG_RUNTIME_DIR /pipewire-0.
  public init() throws(PipeWireError) {
    let dir = (getenv("PIPEWIRE_RUNTIME_DIR") ?? getenv("XDG_RUNTIME_DIR")).map { String(cString: $0) }
    guard let dir else { throw .noServer }
    let path = "\(dir)/\(getenv("PIPEWIRE_REMOTE").map { String(cString: $0) } ?? "pipewire-0")"
    let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard s >= 0 else { throw .system(errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.prefix($0.count - 1)) }
    let ok = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else {
      close(s)
      throw .noServer
    }
    fd = s
  }

  deinit {
    close(fd)
    for f in fdQueue { close(f) }
  }

  /// Sends a method call: `fields` as one Struct, with `fds` attached.
  public func send(_ id: UInt32, _ opcode: UInt8, _ fields: [Pod], fds: [Int32] = []) throws(PipeWireError) {
    var w = PodWriter()
    w.write(.struct(fields))
    let payload = w.bytes
    var header: [UInt32] = [id, UInt32(opcode) << 24 | UInt32(payload.count), seq, UInt32(fds.count)]
    seq = (seq + 1) & 0x3fff_ffff
    var message = header.withUnsafeBytes { Array($0) } + payload
    header.removeAll()
    var control = [UInt8](repeating: 0, count: (MemoryLayout<cmsghdr>.size + 4 * max(fds.count, 1) + 7) & ~7)
    let sent: Int = message.withUnsafeMutableBytes { data in
      control.withUnsafeMutableBytes { ctl in
        var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
        return withUnsafeMutablePointer(to: &iov) { iovp in
          var msg = msghdr()
          msg.msg_iov = iovp
          msg.msg_iovlen = 1
          if !fds.isEmpty {
            let h = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            h.pointee.cmsg_len = MemoryLayout<cmsghdr>.size + 4 * fds.count
            h.pointee.cmsg_level = SOL_SOCKET
            h.pointee.cmsg_type = Int32(SCM_RIGHTS)
            fds.withUnsafeBytes { (ctl.baseAddress! + MemoryLayout<cmsghdr>.size).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            msg.msg_control = ctl.baseAddress
            msg.msg_controllen = ctl.count
          }
          var r: Int
          repeat { r = sendmsg(self.fd, &msg, Int32(MSG_NOSIGNAL)) } while r < 0 && errno == EINTR
          return r
        }
      }
    }
    guard sent == message.count else { throw sent < 0 && errno == EPIPE ? .closed : .system(errno) }
  }

  /// Reads what the socket has and returns every complete message. Doesn't
  /// block.
  public func receive() throws(PipeWireError) -> [PipeWireMessage] {
    var buffer = [UInt8](repeating: 0, count: 65536)
    var control = [UInt8](repeating: 0, count: (MemoryLayout<cmsghdr>.size + 4 * 28 + 7) & ~7)
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
            let h = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self).pointee
            if h.cmsg_level == SOL_SOCKET && h.cmsg_type == Int32(SCM_RIGHTS) {
              let count = (Int(h.cmsg_len) - MemoryLayout<cmsghdr>.size) / 4
              for k in 0..<count {
                self.fdQueue.append((ctl.baseAddress! + MemoryLayout<cmsghdr>.size).loadUnaligned(fromByteOffset: 4 * k, as: Int32.self))
              }
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
    var out: [PipeWireMessage] = []
    var at = 0
    while inBytes.count - at >= 16 {
      func word(_ o: Int) -> UInt32 {
        UInt32(inBytes[o]) | UInt32(inBytes[o + 1]) << 8 | UInt32(inBytes[o + 2]) << 16 | UInt32(inBytes[o + 3]) << 24
      }
      let id = word(at), sizeOp = word(at + 4), nFDs = Int(word(at + 12))
      let size = Int(sizeOp & 0xff_ffff), opcode = UInt8(sizeOp >> 24)
      guard inBytes.count - at >= 16 + size else { break }
      guard nFDs <= fdQueue.count else { throw .protocolError("a message names \(nFDs) fds; \(fdQueue.count) arrived") }
      let fds = Array(fdQueue.prefix(nFDs))
      fdQueue.removeFirst(nFDs)
      var fields: [Pod] = []
      if size >= 8 {
        do {
          let (payload, _) = try readPod(inBytes[(at + 16)..<(at + 16 + size)], at: at + 16)
          fields = payload.fields ?? []
        } catch {
          throw .protocolError("a message that doesn't parse: \(error)")
        }
      }
      out.append(PipeWireMessage(id: id, opcode: opcode, fields: fields, fds: fds))
      at += 16 + size
    }
    inBytes.removeFirst(at)
    return out
  }
}
