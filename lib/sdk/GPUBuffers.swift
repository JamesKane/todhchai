// SPDX-License-Identifier: BSD-3-Clause

// GPU buffers in windows (sdk.md §4, hosted): images a GPU library renders
// into, shared with the compositor as dmabufs through zwp_linux_dmabuf_v1
// over our own Wayland connection. The compositor's dmabuf feedback says
// which device it reads from and which format/modifier pairs it takes.
// Loinnir (lib/loinnir) is the user; this file owns the Wayland side.

import Glibc
import Wayland

/// A pixel format (DRM fourcc) and memory layout (DRM format modifier).
public struct DmabufFormat: Hashable, Sendable {
  public var fourcc: UInt32
  public var modifier: UInt64
  public init(fourcc: UInt32, modifier: UInt64) {
    self.fourcc = fourcc
    self.modifier = modifier
  }

  /// 'XR24': 32-bit xRGB, the format Loinnir presents.
  public static let xrgb8888: UInt32 = 0x3432_5258
  /// DRM_FORMAT_MOD_LINEAR.
  public static let linear: UInt64 = 0
}

/// What the compositor takes.
public struct DmabufFeedback: Sendable {
  /// The device it composites with (a dev_t: render on this one).
  public var mainDevice: UInt64
  /// The formats and modifiers it can import from that device.
  public var formats: Set<DmabufFormat>

  /// dev_t's major and minor numbers (glibc's encoding).
  public var mainDeviceNumbers: (major: UInt32, minor: UInt32) {
    let d = mainDevice
    let major = UInt32(truncatingIfNeeded: ((d >> 8) & 0xfff) | ((d >> 32) & ~0xfff))
    let minor = UInt32(truncatingIfNeeded: (d & 0xff) | ((d >> 12) & ~0xff))
    return (major, minor)
  }
}

/// A dmabuf imported into a window: present it with `present(_:gpuBuffer:)`.
public struct GPUBuffer: Hashable, Sendable {
  public let window: WindowID
  let index: Int
  public let width: Int32
  public let height: Int32
}

/// One imported dmabuf.
struct GPUBufferSlot {
  var buffer: WlBuffer
  var width: Int32
  var height: Int32
  var busy = false
}

/// The feedback being assembled, then complete.
final class DmabufState {
  let dmabuf: ZwpLinuxDmabufV1
  var feedback: ZwpLinuxDmabufFeedbackV1?
  var table: [DmabufFormat] = []
  var mainDevice: UInt64 = 0
  var trancheFormats: Set<DmabufFormat> = []
  var formats: Set<DmabufFormat> = []
  var done = false

  init(_ dmabuf: ZwpLinuxDmabufV1) { self.dmabuf = dmabuf }

  func handle(_ e: ZwpLinuxDmabufFeedbackV1.Event) {
    switch e {
    case .formatTable(let fd, let size):
      // 16-byte entries: u32 format, u32 padding, u64 modifier.
      if let p = mmap(nil, Int(size), PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED {
        table = (0..<(Int(size) / 16)).map { i in
          DmabufFormat(fourcc: p.load(fromByteOffset: 16 * i, as: UInt32.self),
                       modifier: p.load(fromByteOffset: 16 * i + 8, as: UInt64.self))
        }
        munmap(p, Int(size))
      }
      close(fd)
    case .mainDevice(let device):
      mainDevice = device.withUnsafeBytes { $0.count >= 8 ? $0.loadUnaligned(as: UInt64.self) : 0 }
    case .trancheFormats(let indices):
      for k in stride(from: 0, to: indices.count - 1, by: 2) {
        let i = Int(indices[k]) | Int(indices[k + 1]) << 8
        if i < table.count { trancheFormats.insert(table[i]) }
      }
    case .trancheDone:
      formats.formUnion(trancheFormats)
      trancheFormats = []
    case .done:
      done = true
    case .trancheTargetDevice, .trancheFlags:
      break
    }
  }
}

extension Loop {
  /// What the compositor takes for GPU buffers. The first call asks it and
  /// waits for the answer.
  public mutating func dmabufFeedback() throws(WindowError) -> DmabufFeedback {
    let ws = try windowSystem()
    guard let state = ws.dmabuf else { throw .unavailable("the compositor lacks zwp_linux_dmabuf_v1 version 4") }
    if state.feedback == nil {
      state.feedback = state.dmabuf.getDefaultFeedback(ws.c)
      try ws.flush()
    }
    let deadline = Deadline.now + .seconds(5)
    while !state.done {
      guard Deadline.now < deadline else { throw .unavailable("no dmabuf feedback from the compositor") }
      var pfd = pollfd(fd: ws.c.fd, events: Int16(POLLIN), revents: 0)
      if Glibc.poll(&pfd, 1, 100) > 0 { dispatchWayland() }  // Glibc's, not Loop.poll
    }
    return DmabufFeedback(mainDevice: state.mainDevice, formats: state.formats)
  }

  /// Imports a single-plane dmabuf as a buffer for `window`. The fd is
  /// sent to the compositor; the caller keeps (and later closes) its own.
  public mutating func importDmabuf(
    _ window: WindowID, fd: Int32, width: Int32, height: Int32, format: DmabufFormat, offset: UInt32, stride: UInt32
  ) throws(WindowError) -> GPUBuffer {
    let (ws, w) = try self.window(window)
    guard let state = ws.dmabuf else { throw .unavailable("the compositor lacks zwp_linux_dmabuf_v1") }
    let c = ws.c
    let params = state.dmabuf.createParams(c)
    params.add(c, fd: fd, planeIdx: 0, offset: offset, stride: stride,
               modifierHi: UInt32(truncatingIfNeeded: format.modifier >> 32),
               modifierLo: UInt32(truncatingIfNeeded: format.modifier))
    let buffer = params.createImmed(c, width: width, height: height, format: format.fourcc, flags: [])
    params.destroy(c)
    try ws.flush()
    w.gpuBuffers.append(GPUBufferSlot(buffer: buffer, width: width, height: height))
    return GPUBuffer(window: window, index: w.gpuBuffers.count - 1, width: width, height: height)
  }

  /// Whether the compositor still holds `buffer` (presented and not yet
  /// released): don't render into it until it isn't.
  public func isBusy(_ buffer: GPUBuffer) -> Bool {
    guard let (_, w) = try? window(buffer.window), buffer.index < w.gpuBuffers.count else { return false }
    return w.gpuBuffers[buffer.index].busy
  }

  /// Presents a GPU buffer the caller has finished rendering into, drawn
  /// for `configSeq` (a stale one is refused, as CPU surfaces are).
  public mutating func present(_ id: WindowID, gpuBuffer: GPUBuffer, configSeq: UInt64) throws(WindowError) {
    let (ws, w) = try window(id)
    guard let config = w.current, config.configSeq == configSeq, gpuBuffer.index < w.gpuBuffers.count,
      (gpuBuffer.width, gpuBuffer.height) == (config.pixelWidth, config.pixelHeight)
    else { throw .staleConfig }
    w.gpuBuffers[gpuBuffer.index].busy = true
    try commit(ws, w, buffer: w.gpuBuffers[gpuBuffer.index].buffer, width: gpuBuffer.width, height: gpuBuffer.height,
               config: config)
  }

  /// Destroys a window's GPU buffers (before reallocating them for a new
  /// size).
  public mutating func releaseGPUBuffers(_ id: WindowID) {
    guard let (ws, w) = try? window(id) else { return }
    for b in w.gpuBuffers { b.buffer.destroy(ws.c) }
    w.gpuBuffers = []
    try? ws.flush()
  }
}
