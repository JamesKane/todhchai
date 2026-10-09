// SPDX-License-Identifier: BSD-3-Clause

// Windows, surfaces and frames (sdk.md §4), hosted as a Wayland client
// (architecture §18): xdg-shell toplevels, wl_shm buffers for CPU
// surfaces, frame callbacks for the frame clock, wp_presentation for when
// frames reached the glass, and fractional scale through a viewport.

import Glibc
import TDLinux
import Wayland

public enum WindowError: Error, Equatable {
  /// No compositor, or it lacks something windows need (named).
  case unavailable(String)
  /// The window was closed, or never existed.
  case unknownWindow
  /// A buffer drawn for an older configuration (sdk.md §2: never stretched).
  case staleConfig
  /// The compositor connection failed.
  case wayland(WaylandError)
  /// Shared memory for the buffers couldn't be made (errno).
  case system(Int32)
}

/// A window's configuration (sdk.md §2, `configure`).
public struct Configure: Sendable, Equatable {
  /// The size in logical points.
  public var width: Int32
  public var height: Int32
  /// The size of a buffer that fills the window, in pixels.
  public var pixelWidth: Int32
  public var pixelHeight: Int32
  /// Scale as n/120 (120 is 1×, 180 is 1.5×).
  public var scale: UInt32
  /// Buffers presented for this configuration carry this number.
  public var configSeq: UInt64
  public var focused: Bool
  /// The user is resizing it interactively.
  public var resizing: Bool
}

/// A frame clock tick (sdk.md §2, `frame`).
public struct Frame: Sendable, Equatable {
  public var frameSeq: UInt64
  /// The best estimate of when the next frame will reach the glass.
  public var target: Deadline
  /// When the previous frame reached the glass, if known.
  public var presentedAt: Deadline?
  /// The output's refresh interval, if known.
  public var refresh: Duration?
  /// The times are estimates, not measured at vblank.
  public var estimated: Bool
}

/// Pixels to draw into: XRGB8888, `stride` bytes a row. Present it with
/// `Loop.present`, which takes it back.
public struct CPUSurface: ~Copyable {
  public let pixels: UnsafeMutableRawBufferPointer
  public let width: Int32
  public let height: Int32
  public let stride: Int
  /// Frames since this buffer was last presented (0: never), for partial redraw.
  public let age: UInt32
  let window: WindowID
  let buffer: Int

  /// Fills the surface with one XRGB color (0x00RRGGBB).
  public func fill(_ xrgb: UInt32) {
    let words = pixels.bindMemory(to: UInt32.self)
    for i in words.indices { words[i] = xrgb }
  }
}

/// Everything windows need from the compositor, and every window.
final class WindowSystem {
  let c: WaylandConnection
  let compositor: WlCompositor
  let shm: WlShm
  let wm: XdgWmBase
  let presentation: WpPresentation?
  let viewporter: WpViewporter?
  let fractional: WpFractionalScaleManagerV1?
  var presentationClockMonotonic = true
  var windows: [UInt32: WindowState] = [:]  // by window index
  /// Windows owed a `.frame` now: requested before their surface had a
  /// buffer, when no frame callback would ever fire.
  var immediateFrames: [WindowID] = []
  var nextIndex: UInt32 = 1
  var frameSeq: UInt64 = 0

  init() throws(WindowError) {
    let c: WaylandConnection
    do {
      c = try WaylandConnection()
    } catch {
      throw .unavailable("no Wayland compositor ($WAYLAND_DISPLAY)")
    }
    let registry = c.display.getRegistry(c)
    let done = c.display.sync(c)
    var globals: [String: (name: UInt32, version: UInt32)] = [:]
    var finished = false
    do {
      try c.flush()
      while !finished {
        var pfd = pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 5000) == 1 else { throw WindowError.unavailable("the compositor didn't answer") }
        for e in try c.receive() {
          if case .wlRegistry(registry, .global(let name, let interface, let version)) = e {
            globals[interface] = (name, version)
          } else if case .wlCallback(done, .done) = e {
            finished = true
          }
        }
      }
    } catch let e as WindowError {
      throw e
    } catch let e as WaylandError {
      throw .wayland(e)
    } catch {
      throw .unavailable("\(error)")
    }
    func bind<T: WaylandObject>(_ t: T.Type, max: UInt32) -> T? {
      guard let g = globals[T.interface.name] else { return nil }
      return registry.bind(c, T.self, version: min(g.version, max, T.interface.version), name: g.name)
    }
    guard let compositor = bind(WlCompositor.self, max: 6), let shm = bind(WlShm.self, max: 1),
      let wm = bind(XdgWmBase.self, max: 6)
    else { throw .unavailable("the compositor lacks wl_compositor, wl_shm or xdg_wm_base") }
    self.c = c
    self.compositor = compositor
    self.shm = shm
    self.wm = wm
    presentation = bind(WpPresentation.self, max: 1)
    viewporter = bind(WpViewporter.self, max: 1)
    fractional = viewporter == nil ? nil : bind(WpFractionalScaleManagerV1.self, max: 1)
    try flush()
  }

  func flush() throws(WindowError) {
    do { try c.flush() } catch { throw .wayland(error) }
  }
}

/// One shared-memory buffer.
struct ShmBuffer {
  var buffer: WlBuffer
  var offset: Int
  var busy = false  // attached and not yet released by the compositor
  var lastPresented: UInt64 = 0  // frameSeq when last presented; 0 never
}

final class WindowState {
  let id: WindowID
  let surface: WlSurface
  let xdgSurface: XdgSurface
  let toplevel: XdgToplevel
  let viewport: WpViewport?
  let fractionalScale: WpFractionalScaleV1?

  // The configuration being assembled, and the last one acknowledged.
  var pendingWidth: Int32 = 0
  var pendingHeight: Int32 = 0
  var pendingStates: [UInt32] = []
  var requested: (Int32, Int32)
  var scale: UInt32 = 120
  var integerScale: Int32 = 1
  var current: Configure?
  var configured = false

  // Buffers: a pool sized for the current configuration.
  var pool: (fd: Int32, map: UnsafeMutableRawBufferPointer, wl: WlShmPool)?
  var buffers: [ShmBuffer] = []
  var bufferSize: (Int32, Int32) = (0, 0)

  // The frame clock. Until a buffer is presented the surface isn't mapped,
  // and a frame callback wouldn't fire, so frames come from configure.
  // After that every present carries a frame callback in its own commit: a
  // separate commit to ask for one would supersede the presented frame,
  // and the compositor would discard its presentation feedback.
  var mapped = false
  var wantsFrame = false  // the app asked for a frame
  var frameReady = false  // the callback fired before the app asked
  var frameCallback: WlCallback?
  var lastPresented: Deadline?
  var refresh: Duration?
  var measured = false
  var presentedFrames = 0

  init(id: WindowID, surface: WlSurface, xdgSurface: XdgSurface, toplevel: XdgToplevel, viewport: WpViewport?,
       fractionalScale: WpFractionalScaleV1?, requested: (Int32, Int32)) {
    self.id = id
    self.surface = surface
    self.xdgSurface = xdgSurface
    self.toplevel = toplevel
    self.viewport = viewport
    self.fractionalScale = fractionalScale
    self.requested = requested
  }

  func releasePool(_ c: WaylandConnection) {
    for b in buffers { b.buffer.destroy(c) }
    buffers = []
    if let pool {
      pool.wl.destroy(c)
      munmap(pool.map.baseAddress, pool.map.count)
      close(pool.fd)
    }
    pool = nil
  }
}

extension Loop {
  /// The window system, connected on first use.
  mutating func windowSystem() throws(WindowError) -> WindowSystem {
    if let ws = windows { return ws }
    let ws = try WindowSystem()
    windows = ws
    do {
      waylandWatch = try watch(fd: ws.c.fd, for: .readable)
    } catch {
      throw .unavailable("can't watch the compositor's socket")
    }
    return ws
  }

  /// Opens a toplevel window. Its first `.configure` says its size; draw
  /// after that.
  public mutating func openWindow(_ title: String, width: Int32, height: Int32) throws(WindowError) -> WindowID {
    let ws = try windowSystem()
    let c = ws.c
    let surface = ws.compositor.createSurface(c)
    let xdgSurface = ws.wm.getXdgSurface(c, surface: surface)
    let toplevel = xdgSurface.getToplevel(c)
    toplevel.setTitle(c, title: title)
    toplevel.setAppId(c, appId: title)
    let viewport = ws.viewporter?.getViewport(c, surface: surface)
    let fractional = ws.fractional?.getFractionalScale(c, surface: surface)
    let id = WindowID(index: ws.nextIndex, generation: 1)
    ws.nextIndex += 1
    ws.windows[id.index] = WindowState(id: id, surface: surface, xdgSurface: xdgSurface, toplevel: toplevel,
                                       viewport: viewport, fractionalScale: fractional, requested: (width, height))
    surface.commit(c)  // the initial commit asks for the first configure
    try ws.flush()
    return id
  }

  /// Closes a window.
  public mutating func closeWindow(_ id: WindowID) {
    guard let ws = windows, let w = ws.windows.removeValue(forKey: id.index) else { return }
    let c = ws.c
    w.releasePool(c)
    w.fractionalScale?.destroy(c)
    w.viewport?.destroy(c)
    w.toplevel.destroy(c)
    w.xdgSurface.destroy(c)
    w.surface.destroy(c)
    try? ws.flush()
  }

  func window(_ id: WindowID) throws(WindowError) -> (WindowSystem, WindowState) {
    guard let ws = windows, let w = ws.windows[id.index], w.id == id else { throw .unknownWindow }
    return (ws, w)
  }

  /// Asks for a `.frame` event when it's time to draw the next frame.
  /// Coalesced: asking again before it arrives changes nothing.
  public mutating func requestFrame(_ id: WindowID) {
    guard let (ws, w) = try? window(id), !w.wantsFrame else { return }
    w.wantsFrame = true
    if !w.mapped || w.frameReady {
      // Nothing on screen yet, or the frame clock already ticked: draw now
      // (once there's a configuration).
      w.frameReady = false
      if w.current != nil { ws.immediateFrames.append(id) }
      return
    }
    if w.frameCallback == nil {
      // Nothing pending (the app skipped presenting): ask for a callback.
      // This commit carries no new content, so it supersedes nothing unseen.
      w.frameCallback = w.surface.frame(ws.c)
      w.surface.commit(ws.c)
      try? ws.flush()
    }
  }

  /// A buffer to draw the next frame into, sized for the current
  /// configuration; nil before the first configure or if all buffers are
  /// still with the compositor.
  public mutating func cpuSurface(_ id: WindowID) -> CPUSurface? {
    guard let (ws, w) = try? window(id), let config = w.current else { return nil }
    if w.bufferSize != (config.pixelWidth, config.pixelHeight) || w.pool == nil {
      guard (try? makeBuffers(ws, w, config.pixelWidth, config.pixelHeight)) != nil else { return nil }
    }
    guard let pool = w.pool, let i = w.buffers.firstIndex(where: { !$0.busy }) else { return nil }
    let stride = Int(config.pixelWidth) * 4
    let size = stride * Int(config.pixelHeight)
    let b = w.buffers[i]
    let age = b.lastPresented == 0 ? 0 : UInt32(ws.frameSeq - b.lastPresented + 1)
    return CPUSurface(pixels: UnsafeMutableRawBufferPointer(rebasing: pool.map[b.offset..<(b.offset + size)]),
                      width: config.pixelWidth, height: config.pixelHeight, stride: stride, age: age,
                      window: id, buffer: i)
  }

  func makeBuffers(_ ws: WindowSystem, _ w: WindowState, _ width: Int32, _ height: Int32) throws(WindowError) {
    w.releasePool(ws.c)
    let size = Int(width) * Int(height) * 4
    let count = 3
    let fd = td_linux_memfd("todhchai-cpu-surface")
    guard fd >= 0 else { throw .system(errno) }
    guard ftruncate(fd, off_t(size * count)) == 0, let p = mmap(nil, size * count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
      p != MAP_FAILED
    else {
      close(fd)
      throw .system(errno)
    }
    let pool = ws.shm.createPool(ws.c, fd: fd, size: Int32(size * count))
    w.pool = (fd, UnsafeMutableRawBufferPointer(start: p, count: size * count), pool)
    w.buffers = (0..<count).map { k in
      ShmBuffer(buffer: pool.createBuffer(ws.c, offset: Int32(k * size), width: width, height: height,
                                          stride: width * 4, format: .xrgb8888),
                offset: k * size)
    }
    w.bufferSize = (width, height)
  }

  /// Presents a drawn surface. It must have been drawn for `configSeq`,
  /// the window's current configuration; a stale one is refused, never
  /// stretched.
  public mutating func present(_ id: WindowID, _ surface: consuming CPUSurface, configSeq: UInt64) throws(WindowError) {
    let (ws, w) = try window(id)
    let index = surface.buffer
    guard let config = w.current, config.configSeq == configSeq,
      (surface.width, surface.height) == (config.pixelWidth, config.pixelHeight), index < w.buffers.count
    else { throw .staleConfig }
    let c = ws.c
    ws.frameSeq += 1
    w.buffers[index].busy = true
    w.buffers[index].lastPresented = ws.frameSeq
    w.mapped = true
    w.surface.attach(c, buffer: w.buffers[index].buffer, x: 0, y: 0)
    w.surface.damageBuffer(c, x: 0, y: 0, width: surface.width, height: surface.height)
    if let viewport = w.viewport {
      viewport.setDestination(c, width: config.width, height: config.height)
    } else {
      w.surface.setBufferScale(c, scale: w.integerScale)
    }
    if let presentation = ws.presentation { _ = presentation.feedback(c, surface: w.surface) }
    if w.frameCallback == nil { w.frameCallback = w.surface.frame(c) }  // in this commit, never one of its own
    w.frameReady = false
    w.surface.commit(c)
    try ws.flush()
  }

  // MARK: Events from the compositor

  /// Reads the compositor's events and turns them into window events.
  mutating func dispatchWayland() {
    guard let ws = windows else { return }
    let events: [WaylandEvent]
    do {
      events = try ws.c.receive()
    } catch {
      append(.quit)  // the compositor went away: nothing more can be shown
      return
    }
    for e in events { handle(e, ws) }
    try? ws.flush()
  }

  func state(_ ws: WindowSystem, where match: (WindowState) -> Bool) -> WindowState? {
    ws.windows.values.first(where: match)
  }

  mutating func handle(_ e: WaylandEvent, _ ws: WindowSystem) {
    let c = ws.c
    switch e {
    case .xdgWmBase(let wm, .ping(let serial)):
      wm.pong(c, serial: serial)
    case .wpPresentation(_, .clockId(let clock)):
      ws.presentationClockMonotonic = clock == UInt32(CLOCK_MONOTONIC)
    case .xdgToplevel(let t, .configure(let width, let height, let states)):
      guard let w = state(ws, where: { $0.toplevel == t }) else { return }
      w.pendingWidth = width
      w.pendingHeight = height
      w.pendingStates = states.withUnsafeBytes { raw in (0..<(raw.count / 4)).map { raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self) } }
    case .xdgToplevel(let t, .close):
      guard let w = state(ws, where: { $0.toplevel == t }) else { return }
      append(.close, window: w.id)
    case .xdgSurface(let s, .configure(let serial)):
      guard let w = state(ws, where: { $0.xdgSurface == s }) else { return }
      s.ackConfigure(c, serial: serial)
      emitConfigure(w, serial: UInt64(serial))
    case .wpFractionalScaleV1(let f, .preferredScale(let scale)):
      guard let w = state(ws, where: { $0.fractionalScale == f }) else { return }
      w.scale = scale
      if let current = w.current { emitConfigure(w, serial: current.configSeq) }
    case .wlSurface(let s, .preferredBufferScale(let factor)):
      guard let w = state(ws, where: { $0.surface == s }), w.fractionalScale == nil else { return }
      w.integerScale = max(1, factor)
      w.scale = UInt32(max(1, factor)) * 120
      if let current = w.current { emitConfigure(w, serial: current.configSeq) }
    case .wlBuffer(let b, .release):
      for w in ws.windows.values {
        if let i = w.buffers.firstIndex(where: { $0.buffer == b }) { w.buffers[i].busy = false }
      }
    case .wlCallback(let cb, .done):
      guard let w = state(ws, where: { $0.frameCallback == cb }) else { return }
      w.frameCallback = nil
      if w.wantsFrame { emitFrame(w, ws) } else { w.frameReady = true }
    case .wpPresentationFeedback(_, .presented(let hi, let lo, let nsec, let refresh, _, _, let flags)):
      // Feedback belongs to the window that committed it; with one window
      // pending at a time per surface this is exact, and every window
      // shares an output's timing otherwise.
      let ns = (UInt64(hi) << 32 | UInt64(lo)) * 1_000_000_000 + UInt64(nsec)
      for w in ws.windows.values {
        w.lastPresented = ws.presentationClockMonotonic ? Deadline(ns: ns) : .now
        if refresh > 0 { w.refresh = .nanoseconds(Int64(refresh)) }
        w.measured = flags.contains(.vsync) && flags.contains(.hwClock)
        w.presentedFrames += 1
      }
    default:
      break
    }
  }

  mutating func emitConfigure(_ w: WindowState, serial: UInt64) {
    w.configured = true
    let width = w.pendingWidth > 0 ? w.pendingWidth : (w.current?.width ?? w.requested.0)
    let height = w.pendingHeight > 0 ? w.pendingHeight : (w.current?.height ?? w.requested.1)
    let pixelWidth = Int32((Int(width) * Int(w.scale) + 60) / 120)
    let pixelHeight = Int32((Int(height) * Int(w.scale) + 60) / 120)
    // xdg_toplevel states: 3 resizing, 4 activated.
    let config = Configure(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                           scale: w.scale, configSeq: serial, focused: w.pendingStates.contains(4),
                           resizing: w.pendingStates.contains(3))
    w.current = config
    append(.configure(config), window: w.id)
    if w.wantsFrame && !w.mapped { emitFrame(w, windows!) }
  }

  /// Frames owed to windows that aren't mapped yet; true if there were any.
  mutating func emitImmediateFrames() -> Bool {
    guard let ws = windows, !ws.immediateFrames.isEmpty else { return false }
    let ids = ws.immediateFrames
    ws.immediateFrames.removeAll()
    for id in ids {
      if let w = ws.windows[id.index], w.id == id, w.wantsFrame { emitFrame(w, ws) }
    }
    return true
  }

  mutating func emitFrame(_ w: WindowState, _ ws: WindowSystem) {
    w.wantsFrame = false
    let now = Deadline.now
    var target = now
    if let last = w.lastPresented, let refresh = w.refresh, refresh.nanoseconds > 0 {
      let step = refresh.nanoseconds
      let ahead = now.ns > last.ns ? (now.ns - last.ns) / step + 1 : 1
      target = Deadline(ns: last.ns + ahead * step)
    }
    let frame = Frame(frameSeq: ws.frameSeq + 1, target: target, presentedAt: w.lastPresented, refresh: w.refresh,
                      estimated: !w.measured)
    append(.frame(frame), window: w.id)
  }
}
