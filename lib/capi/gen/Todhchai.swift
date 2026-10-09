// SPDX-License-Identifier: BSD-3-Clause

// libtodhchai's C ABI (sdk.md §12), v0: the loop, timers, windows with CPU
// surfaces, input, and sound. Conventions:
//   - `td_` prefix. `td_loop *` is the one pointer (its lifetime is the
//     process's own); windows and sounds are 64-bit generation handles.
//   - Input structs start with `uint32_t size`; output structs belong to
//     the caller.
//   - Fallible calls return `td_status`, or an invalid handle or NULL, and
//     `td_last_error()` says why, per thread. A stale handle is ignored.
//   - Events are 80-byte records, valid until the next wait.

/// Pairs (name, HID usage) from KeyUsage.swift, read by `keyUsages(in:)`.
public typealias KeyList = [(name: String, usage: UInt16)]

public func todhchaiABI(keys: KeyList) -> ABI {
  let window = CType.named("td_window")
  let loop = CType.opaque("td_loop")
  let status = CType.named("td_status")

  func record(_ name: String, _ doc: String, union: Bool = false, anonymous: Bool = false, _ fields: [Field]) -> Decl {
    .record(Record(name: name, isUnion: union, fields: fields, doc: doc, anonymousInC: anonymous))
  }
  func fn(_ name: String, _ returns: CType, _ params: [Field], _ doc: String) -> Decl {
    .function(Function(name: name, returns: returns, params: params, doc: doc))
  }

  var d: [Decl] = []

  d += [
    .section("Status and errors"),
    .alias("td_status", .i32, doc: "0 is success; errors are negative. The values are td_kernel.h's where they overlap."),
    .constants(type: .i32, [
      Constant("TD_OK", 0),
      Constant("TD_ERR_NOT_SUPPORTED", -2, "The system lacks something this needs (td_last_error names it)."),
      Constant("TD_ERR_INVALID_ARGS", -10, "A NULL, a size too small for the struct, or a value out of range."),
      Constant("TD_ERR_BAD_HANDLE", -11, "The handle is stale or was never valid."),
      Constant("TD_ERR_STALE_CONFIG", -40, "Drawn for an older configuration: draw again for the newest (sdk.md §2)."),
      Constant("TD_ERR_IO", -41, "A system call failed (td_last_error has errno's text)."),
      Constant("TD_ERR_BAD_FORMAT", -42, "A file isn't in a format this reads."),
    ], doc: "td_status values."),
    fn("td_last_error", .cString, [],
       "Why this thread's last call failed, or \"\". Valid until this thread's next call that fails."),
  ]

  d += [
    .section("Time"),
    .constants(type: .u64, [Constant("TD_FOREVER", -1, "A deadline that never comes.")], doc: ""),
    fn("td_now", .u64, [], "The monotonic clock, in nanoseconds."),
  ]

  d += [
    .section("Handles"),
    record("td_window", "A window. {0, 0} is none.", [Field("index", .u32), Field("generation", .u32)]),
    record("td_sound", "A decoded sound. {0, 0} is none.", [Field("index", .u32), Field("generation", .u32)]),
  ]

  d += [
    .section("Events"),
    .constants(type: .u16, [
      Constant("TD_EV_TIMER", 1, "A timer's deadline came: `timer`."),
      Constant("TD_EV_WATCH", 2, "Reserved: watched handles join the C ABI later."),
      Constant("TD_EV_MESSAGE", 3, "A message posted to the loop: `message`."),
      Constant("TD_EV_WAKE", 4, "The loop was woken (td_loop_wake)."),
      Constant("TD_EV_QUIT", 5, "The process was asked to stop (SIGINT, SIGTERM)."),
      Constant("TD_EV_CONFIGURE", 6, "A window's size, scale or state changed: `configure`."),
      Constant("TD_EV_CLOSE", 7, "The user asked to close a window."),
      Constant("TD_EV_FRAME", 8, "Time to draw a window's next frame: `frame`."),
      Constant("TD_EV_KEY_DOWN", 9, "A key went down, or repeats: `key`."),
      Constant("TD_EV_KEY_UP", 10, "A key came up: `key`."),
      Constant("TD_EV_POINTER", 11, "The pointer entered, left, moved, or a button changed: `pointer`."),
      Constant("TD_EV_WHEEL", 12, "A wheel or touchpad scrolled: `wheel`."),
    ], doc: "td_event.kind."),
    .constants(type: .u32, [
      Constant("TD_CONFIGURE_FOCUSED", 1, "The window has keyboard focus."),
      Constant("TD_CONFIGURE_RESIZING", 2, "An interactive resize is under way."),
    ], doc: "td_configure_event.flags."),
    record("td_configure_event", "TD_EV_CONFIGURE: draw for `config_seq`.", [
      Field("width", .i32, "Logical size."), Field("height", .i32),
      Field("pixel_width", .i32, "The size to draw at."), Field("pixel_height", .i32),
      Field("scale", .u32, "Scale × 120 (120 is 1×)."),
      Field("flags", .u32, "TD_CONFIGURE_*."),
      Field("config_seq", .u64, "Pass to td_present."),
    ]),
    .constants(type: .u32, [Constant("TD_FRAME_ESTIMATED", 1, "The target time is estimated, not from the display.")],
               doc: "td_frame_event.flags."),
    record("td_frame_event", "TD_EV_FRAME.", [
      Field("frame_seq", .u64),
      Field("target", .u64, "When this frame is expected on the glass (td_now's clock)."),
      Field("presented_at", .u64, "When the previous frame reached the glass; 0 if unknown."),
      Field("refresh", .u64, "The display's refresh interval in ns; 0 if unknown."),
      Field("flags", .u32, "TD_FRAME_*."),
    ]),
    .constants(type: .u8, [
      Constant("TD_MOD_SHIFT", 1), Constant("TD_MOD_CONTROL", 2), Constant("TD_MOD_ALT", 4), Constant("TD_MOD_SUPER", 8),
      Constant("TD_MOD_CAPS_LOCK", 16), Constant("TD_MOD_NUM_LOCK", 32),
    ], doc: "Modifier bits."),
    record("td_key_event", "TD_EV_KEY_DOWN, TD_EV_KEY_UP.", [
      Field("usage", .u16, "The physical key: a HID keyboard usage, TD_KEY_*."),
      Field("modifiers", .u8, "TD_MOD_*."),
      Field("is_repeat", .bool, "Held down and repeating."),
      Field("scancode", .u32, "The platform's code, for remapping UIs."),
    ]),
    .constants(type: .u8, [
      Constant("TD_POINTER_ENTER", 1), Constant("TD_POINTER_LEAVE", 2), Constant("TD_POINTER_MOTION", 3),
      Constant("TD_POINTER_DOWN", 4), Constant("TD_POINTER_UP", 5),
    ], doc: "td_pointer_event.action."),
    .constants(type: .u32, [
      Constant("TD_BUTTON_LEFT", 1), Constant("TD_BUTTON_RIGHT", 2), Constant("TD_BUTTON_MIDDLE", 3),
      Constant("TD_BUTTON_BACK", 4), Constant("TD_BUTTON_FORWARD", 5),
    ], doc: "td_pointer_event.button; other buttons are the platform's code plus 256."),
    record("td_pointer_event", "TD_EV_POINTER.", [
      Field("x", .f64, "Position in logical units."), Field("y", .f64),
      Field("action", .u8, "TD_POINTER_*."),
      Field("modifiers", .u8, "TD_MOD_*."),
      Field("button", .u32, "For DOWN and UP: TD_BUTTON_*."),
    ]),
    record("td_wheel_event", "TD_EV_WHEEL.", [
      Field("dx", .f64, "Scroll distance in logical units."), Field("dy", .f64),
      Field("steps_x", .f64, "Wheel detents, where the device has them."), Field("steps_y", .f64),
      Field("modifiers", .u8, "TD_MOD_*."),
    ]),
    record("td_timer_event", "TD_EV_TIMER.", [
      Field("timer", .u64, "From td_timer_set."),
      Field("missed", .u64, "Repeats skipped because the loop was late."),
    ]),
    record("td_message_event", "TD_EV_MESSAGE.", [Field("a", .u64), Field("b", .u64)]),
    record("td_event_payload", "The kind's data.", union: true, anonymous: true, [
      Field("configure", .named("td_configure_event")),
      Field("frame", .named("td_frame_event")),
      Field("key", .named("td_key_event")),
      Field("pointer", .named("td_pointer_event")),
      Field("wheel", .named("td_wheel_event")),
      Field("timer", .named("td_timer_event")),
      Field("message", .named("td_message_event")),
      Field("bytes", .array(.u8, 48)),
    ]),
    record("td_event", "One event: 80 bytes (sdk.md §2).", [
      Field("kind", .u16, "TD_EV_*."),
      Field("flags", .u16, "Reserved: 0."),
      Field("window", window, "The window it's for, or {0, 0}."),
      Field("time", .u64, "When it was taken (td_now's clock)."),
      Field("seq", .u64, "Its place in the loop's sequence, from 1."),
      Field("payload", .named("td_event_payload")),
    ]),
    record("td_events", "The events one wait returned: valid until the next wait on the same loop.", [
      Field("items", .pointer(.named("td_event"), const: true)),
      Field("count", .usize),
    ]),
  ]

  d += [
    .section("The loop"),
    .opaque("td_loop", doc: "A run loop: one per thread that waits."),
    fn("td_loop_create", loop, [], "A loop for this thread, or NULL (td_last_error says why)."),
    fn("td_loop_destroy", .void, [Field("loop", loop)], "Closes its windows and frees it."),
    fn("td_loop_wait", .named("td_events"), [
      Field("loop", loop), Field("deadline", .u64, "td_now's clock, or TD_FOREVER."),
      Field("leeway", .u64, "How late (ns) waking may be, to share wakeups."),
    ], "Waits until there are events or `deadline`; frames come last in a batch."),
    fn("td_loop_poll", .named("td_events"), [Field("loop", loop)], "The events ready now, without waiting."),
    fn("td_loop_wake", .void, [Field("loop", loop)], "Wakes the loop (TD_EV_WAKE), from any thread."),
    fn("td_loop_post", .void, [Field("loop", loop), Field("a", .u64), Field("b", .u64)],
       "Posts TD_EV_MESSAGE, from any thread."),
    fn("td_timer_set", .u64, [
      Field("loop", loop), Field("deadline", .u64), Field("leeway", .u64),
      Field("repeat", .u64, "The interval in ns, or 0 for once."),
    ], "A timer; TD_EV_TIMER carries the returned id."),
    fn("td_timer_cancel", .void, [Field("loop", loop), Field("timer", .u64)], "Cancels a timer."),
  ]

  d += [
    .section("Windows"),
    record("td_window_desc", "A window to open (an input struct: set `size`).", [
      Field("size", .u32, "sizeof(td_window_desc)."),
      Field("flags", .u32, "Reserved: 0."),
      Field("title", .cString),
      Field("width", .i32, "Logical size."), Field("height", .i32),
    ]),
    fn("td_window_open", window, [Field("loop", loop), Field("title", .cString), Field("width", .i32), Field("height", .i32)],
       "Opens a window; {0, 0} on failure. TD_EV_CONFIGURE follows."),
    fn("td_window_open_desc", window, [Field("loop", loop), Field("desc", .pointer(.named("td_window_desc"), const: true))],
       "td_window_open, from a description."),
    fn("td_window_close", .void, [Field("loop", loop), Field("window", window)], "Closes a window."),
    fn("td_frame_request", .void, [Field("loop", loop), Field("window", window)],
       "Asks for one TD_EV_FRAME, when it's time to draw."),
    record("td_cpu_surface", "Pixels to draw into, XRGB8888 (an output struct).", [
      Field("pixels", .pointer(.void, const: false)),
      Field("width", .i32), Field("height", .i32),
      Field("stride", .u32, "Bytes a row."),
      Field("age", .u32, "Frames since this buffer was last shown (0: never), for partial redraw."),
      Field("window", window),
      Field("buffer", .u32, "The SDK's own: leave it."),
      Field("reserved", .u32),
    ]),
    fn("td_cpu_surface_acquire", .bool, [Field("loop", loop), Field("window", window), Field("out", .pointer(.named("td_cpu_surface"), const: false))],
       "A surface for this frame; false before the first configure or while every buffer is on screen."),
    fn("td_fill", .void, [Field("surface", .pointer(.named("td_cpu_surface"), const: true)), Field("xrgb", .u32)],
       "Fills a surface with one color, 0x00RRGGBB."),
    fn("td_present", status, [
      Field("loop", loop), Field("window", window), Field("surface", .pointer(.named("td_cpu_surface"), const: true)),
      Field("config_seq", .u64),
    ], "Shows a drawn surface. TD_ERR_STALE_CONFIG if drawn for an older configuration."),
  ]

  d += [
    .section("Sound"),
    fn("td_sound_load", .named("td_sound"), [Field("path", .cString)], "Decodes a WAV file; {0, 0} on failure."),
    fn("td_sound_free", .void, [Field("sound", .named("td_sound"))], "Frees a sound once no voice plays it."),
    fn("td_mixer_play", .u32, [Field("sound", .named("td_sound")), Field("gain", .f32)],
       "Plays a sound on the shared mixer; returns a voice, or 0 if it couldn't."),
    fn("td_mixer_stop", .void, [Field("voice", .u32)], "Stops a voice."),
  ]

  d += [
    .section("Keys: HID keyboard usages (lib/sdk/KeyUsage.swift)"),
    .constants(type: .u16, keys.map { Constant("TD_KEY_" + upperSnake($0.name), Int64($0.usage)) }, doc: ""),
  ]

  return ABI(prefix: "td_", decls: d)
}

/// The `public static let name = KeyUsage(rawValue: 0x..)` pairs in
/// KeyUsage.swift's source, in order.
public func keyUsages(in source: String) -> KeyList {
  var out: KeyList = []
  for line in source.split(separator: "\n") where line.contains("static let") && line.contains("KeyUsage(rawValue:") {
    for part in line.split(separator: ",", omittingEmptySubsequences: true) {
      // "  public static let a = KeyUsage(rawValue: 0x04)" or " b = KeyUsage(rawValue: 0x05)"
      guard let eq = part.firstIndex(of: "="), let colon = part.firstIndex(of: ":") else { continue }
      let name = part[..<eq].split(separator: " ").last.map(String.init) ?? ""
      let digits = part[part.index(after: colon)...].drop { $0 == " " }.dropFirst(2).prefix { $0.isHexDigit }
      if !name.isEmpty, let v = UInt16(digits, radix: 16) { out.append((name, v)) }
    }
  }
  return out
}
