// SPDX-License-Identifier: BSD-3-Clause

// libtodhchai's C ABI (sdk.md §12), over the hosted SDK. The declarations
// are the generated todhchai.h (lib/capi/gen); this file implements them
// with @c. Nothing here panics on misuse: NULLs and stale handles are
// reported through td_status and td_last_error.

import Glibc
import Synchronization
import TDCABI
import Todhchai

// MARK: Errors

let errorKey: pthread_key_t = {
  var key = pthread_key_t()
  pthread_key_create(&key) { free($0) }
  return key
}()
nonisolated(unsafe) let noError = UnsafePointer(strdup("")!)  // never written

func fail(_ message: String) {
  free(pthread_getspecific(errorKey))
  pthread_setspecific(errorKey, strdup(message))
}

@c public func td_last_error() -> UnsafePointer<CChar>? {
  pthread_getspecific(errorKey).map { UnsafePointer($0.assumingMemoryBound(to: CChar.self)) } ?? noError
}

func status(_ e: WindowError) -> td_status {
  fail("\(e)")
  return switch e {
  case .staleConfig: TD_ERR_STALE_CONFIG
  case .unknownWindow: TD_ERR_BAD_HANDLE
  case .unavailable: TD_ERR_NOT_SUPPORTED
  case .wayland, .system: TD_ERR_IO
  }
}

// MARK: Time

@c public func td_now() -> UInt64 { Deadline.now.ns }

// MARK: The loop

/// What a `td_loop *` points at: the loop, and the buffer its events are
/// returned in (valid until the next wait).
final class LoopBox {
  var loop: Loop
  var events: UnsafeMutablePointer<td_event>
  var capacity = 64
  init(_ loop: consuming Loop) {
    self.loop = loop
    events = .allocate(capacity: capacity)
  }
  deinit { events.deallocate() }

  func deliver(_ batch: Events) -> td_events {
    if batch.count > capacity {
      events.deallocate()
      capacity = max(batch.count, capacity * 2)
      events = .allocate(capacity: capacity)
    }
    for (i, e) in batch.enumerated() { events[i] = convert(e) }
    return td_events(items: UnsafePointer(events), count: batch.count)
  }
}

func box(_ loop: OpaquePointer?) -> LoopBox? {
  guard let loop else {
    fail("the loop is NULL")
    return nil
  }
  return Unmanaged<LoopBox>.fromOpaque(UnsafeRawPointer(loop)).takeUnretainedValue()
}

@c public func td_loop_create() -> OpaquePointer? {
  do {
    return OpaquePointer(Unmanaged.passRetained(LoopBox(try Loop())).toOpaque())
  } catch {
    fail("\(error)")
    return nil
  }
}

@c public func td_loop_destroy(_ loop: OpaquePointer?) {
  guard let loop else { return }
  Unmanaged<LoopBox>.fromOpaque(UnsafeRawPointer(loop)).release()
}

@c public func td_loop_wait(_ loop: OpaquePointer?, _ deadline: UInt64, _ leeway: UInt64) -> td_events {
  guard let b = box(loop) else { return td_events(items: nil, count: 0) }
  let until = deadline == UInt64.max ? nil : Deadline(ns: deadline)
  return b.deliver(b.loop.wait(until: until, leeway: .nanoseconds(Int64(min(leeway, UInt64(Int64.max))))))
}

@c public func td_loop_poll(_ loop: OpaquePointer?) -> td_events {
  guard let b = box(loop) else { return td_events(items: nil, count: 0) }
  return b.deliver(b.loop.poll())
}

@c public func td_loop_wake(_ loop: OpaquePointer?) { box(loop)?.loop.wake() }

@c public func td_loop_post(_ loop: OpaquePointer?, _ a: UInt64, _ b: UInt64) { box(loop)?.loop.post(Message(a, b)) }

@c public func td_timer_set(_ loop: OpaquePointer?, _ deadline: UInt64, _ leeway: UInt64, _ repeatNs: UInt64) -> UInt64 {
  guard let b = box(loop) else { return 0 }
  return b.loop.timer(at: Deadline(ns: deadline), leeway: .nanoseconds(Int64(min(leeway, UInt64(Int64.max)))),
                      repeating: repeatNs == 0 ? nil : .nanoseconds(Int64(min(repeatNs, UInt64(Int64.max))))).raw
}

@c public func td_timer_cancel(_ loop: OpaquePointer?, _ timer: UInt64) { box(loop)?.loop.cancel(TimerID(c: timer)) }

// MARK: Events

func id(_ w: td_window) -> WindowID { WindowID(c: w.index, w.generation) }
func handle(_ w: WindowID) -> td_window { td_window(index: w.index, generation: w.generation) }

func convert(_ e: Event) -> td_event {
  var c = td_event()
  c.window = handle(e.window)
  c.time = e.time.ns
  c.seq = e.seq
  func key(_ k: Key) -> td_key_event {
    td_key_event(usage: k.usage.rawValue, modifiers: k.modifiers.rawValue, is_repeat: k.isRepeat, scancode: k.scancode)
  }
  func button(_ b: PointerButton) -> UInt32 {
    switch b {
    case .left: TD_BUTTON_LEFT
    case .right: TD_BUTTON_RIGHT
    case .middle: TD_BUTTON_MIDDLE
    case .back: TD_BUTTON_BACK
    case .forward: TD_BUTTON_FORWARD
    case .other(let code): code &+ 256
    }
  }
  switch e.payload {
  case .timer(let t, let missed):
    c.kind = UInt16(TD_EV_TIMER)
    c.timer = td_timer_event(timer: t.raw, missed: missed)
  case .watch:
    c.kind = UInt16(TD_EV_WATCH)
  case .message(let m):
    c.kind = UInt16(TD_EV_MESSAGE)
    c.message = td_message_event(a: m.a, b: m.b)
  case .wake: c.kind = UInt16(TD_EV_WAKE)
  case .quit: c.kind = UInt16(TD_EV_QUIT)
  case .configure(let k):
    c.kind = UInt16(TD_EV_CONFIGURE)
    c.configure = td_configure_event(
      width: k.width, height: k.height, pixel_width: k.pixelWidth, pixel_height: k.pixelHeight, scale: k.scale,
      flags: (k.focused ? TD_CONFIGURE_FOCUSED : 0) | (k.resizing ? TD_CONFIGURE_RESIZING : 0), config_seq: k.configSeq)
  case .close: c.kind = UInt16(TD_EV_CLOSE)
  case .frame(let f):
    c.kind = UInt16(TD_EV_FRAME)
    c.frame = td_frame_event(frame_seq: f.frameSeq, target: f.target.ns, presented_at: f.presentedAt?.ns ?? 0,
                             refresh: f.refresh?.nanoseconds ?? 0, flags: f.estimated ? TD_FRAME_ESTIMATED : 0)
  case .keyDown(let k):
    c.kind = UInt16(TD_EV_KEY_DOWN)
    c.key = key(k)
  case .keyUp(let k):
    c.kind = UInt16(TD_EV_KEY_UP)
    c.key = key(k)
  case .pointer(let p):
    c.kind = UInt16(TD_EV_POINTER)
    var out = td_pointer_event()
    out.x = p.x
    out.y = p.y
    out.modifiers = p.modifiers.rawValue
    switch p.action {
    case .enter: out.action = UInt8(TD_POINTER_ENTER)
    case .leave: out.action = UInt8(TD_POINTER_LEAVE)
    case .motion: out.action = UInt8(TD_POINTER_MOTION)
    case .down(let b):
      out.action = UInt8(TD_POINTER_DOWN)
      out.button = button(b)
    case .up(let b):
      out.action = UInt8(TD_POINTER_UP)
      out.button = button(b)
    }
    c.pointer = out
  case .wheel(let w):
    c.kind = UInt16(TD_EV_WHEEL)
    c.wheel = td_wheel_event(dx: w.dx, dy: w.dy, steps_x: w.stepsX, steps_y: w.stepsY, modifiers: w.modifiers.rawValue)
  }
  return c
}

// MARK: Windows

@c public func td_window_open(_ loop: OpaquePointer?, _ title: UnsafePointer<CChar>?, _ width: Int32, _ height: Int32)
  -> td_window
{
  guard let b = box(loop) else { return td_window() }
  guard width > 0, height > 0 else {
    fail("a window's size must be positive (\(width) × \(height))")
    return td_window()
  }
  do {
    return handle(try b.loop.openWindow(title.map { String(cString: $0) } ?? "", width: width, height: height))
  } catch {
    _ = status(error)
    return td_window()
  }
}

@c public func td_window_open_desc(_ loop: OpaquePointer?, _ desc: UnsafePointer<td_window_desc>?) -> td_window {
  // A caller built against this header or a newer one: newer fields past
  // ours are ignored. An older, shorter struct isn't a v0 caller.
  guard let desc, desc.pointee.size >= UInt32(MemoryLayout<td_window_desc>.size) else {
    fail("td_window_desc is NULL or its size is too small")
    return td_window()
  }
  return td_window_open(loop, desc.pointee.title, desc.pointee.width, desc.pointee.height)
}

@c public func td_window_close(_ loop: OpaquePointer?, _ window: td_window) { box(loop)?.loop.closeWindow(id(window)) }

@c public func td_frame_request(_ loop: OpaquePointer?, _ window: td_window) { box(loop)?.loop.requestFrame(id(window)) }

@c public func td_cpu_surface_acquire(_ loop: OpaquePointer?, _ window: td_window, _ out: UnsafeMutablePointer<td_cpu_surface>?)
  -> Bool
{
  guard let b = box(loop), let out else { return false }
  guard let s = b.loop.cpuSurface(id(window)) else { return false }
  out.pointee = td_cpu_surface(pixels: s.pixels.baseAddress, width: s.width, height: s.height, stride: UInt32(s.stride),
                               age: s.age, window: window, buffer: UInt32(s.bufferIndex), reserved: 0)
  return true
}

@c public func td_fill(_ surface: UnsafePointer<td_cpu_surface>?, _ xrgb: UInt32) {
  guard let s = surface?.pointee, let pixels = s.pixels, s.width > 0, s.height > 0 else { return }
  for y in 0..<Int(s.height) {
    let row = (pixels + y * Int(s.stride)).assumingMemoryBound(to: UInt32.self)
    for x in 0..<Int(s.width) { row[x] = xrgb }
  }
}

@c public func td_present(_ loop: OpaquePointer?, _ window: td_window, _ surface: UnsafePointer<td_cpu_surface>?,
                          _ configSeq: UInt64) -> td_status {
  guard let b = box(loop) else { return TD_ERR_INVALID_ARGS }
  guard let s = surface?.pointee, let pixels = s.pixels, s.window.index == window.index,
    s.window.generation == window.generation
  else {
    fail("the surface is NULL or isn't this window's")
    return TD_ERR_INVALID_ARGS
  }
  let surface = CPUSurface(c: id(window), buffer: Int(s.buffer),
                           pixels: UnsafeMutableRawBufferPointer(start: pixels, count: Int(s.stride) * Int(s.height)),
                           width: s.width, height: s.height, stride: Int(s.stride), age: s.age)
  do {
    try b.loop.present(id(window), surface, configSeq: configSeq)
    return TD_OK
  } catch {
    return status(error)
  }
}

// MARK: Sound

/// Sounds by generation handle; index 0 is never used.
struct SoundTable {
  var slots: [(generation: UInt32, sound: Sound?)] = [(0, nil)]
  var free: [UInt32] = []
}
let sounds = Mutex(SoundTable())

func lookup(_ h: td_sound) -> Sound? {
  sounds.withLock { t in
    guard h.index != 0, Int(h.index) < t.slots.count, t.slots[Int(h.index)].generation == h.generation else { return nil }
    return t.slots[Int(h.index)].sound
  }
}

@c public func td_sound_load(_ path: UnsafePointer<CChar>?) -> td_sound {
  guard let path else {
    fail("the path is NULL")
    return td_sound()
  }
  let sound: Sound
  do {
    sound = try Sound.load(String(cString: path))
  } catch {
    fail("\(error)")
    return td_sound()
  }
  return sounds.withLock { t in
    if let i = t.free.popLast() {
      t.slots[Int(i)].sound = sound
      return td_sound(index: i, generation: t.slots[Int(i)].generation)
    }
    t.slots.append((1, sound))
    return td_sound(index: UInt32(t.slots.count - 1), generation: 1)
  }
}

@c public func td_sound_free(_ sound: td_sound) {
  sounds.withLock { t in
    guard sound.index != 0, Int(sound.index) < t.slots.count, t.slots[Int(sound.index)].generation == sound.generation
    else { return }
    t.slots[Int(sound.index)] = (sound.generation &+ 1, nil)
    t.free.append(sound.index)
  }
}

@c public func td_mixer_play(_ sound: td_sound, _ gain: Float) -> UInt32 {
  guard let s = lookup(sound) else {
    fail("td_mixer_play: the sound is stale or none")
    return 0
  }
  guard let voice = Mixer.shared.play(s, gain: gain) else {
    fail("td_mixer_play: no audio output, or the mixer is busy")
    return 0
  }
  return voice.raw &+ 1  // 0 is none
}

@c public func td_mixer_stop(_ voice: UInt32) {
  if voice != 0 { Mixer.shared.stop(VoiceID(c: voice &- 1)) }
}
