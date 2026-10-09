// SPDX-License-Identifier: BSD-3-Clause

// Keys by HID usage (sdk.md §6): the keyboard page (0x07) of the USB-IF
// HID Usage Tables 1.5, §10, names the physical key whatever the layout,
// so `.w` is the same key on QWERTY and AZERTY.
//
// The hosted backend gets Linux evdev keycodes (the kernel's UAPI
// input-event-codes.h). The table from one to the other is ours, matching
// the two specifications key by key; both are data (principle 29).

/// A key, as a HID keyboard-page usage.
public struct KeyUsage: RawRepresentable, Hashable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let a = KeyUsage(rawValue: 0x04), b = KeyUsage(rawValue: 0x05), c = KeyUsage(rawValue: 0x06)
  public static let d = KeyUsage(rawValue: 0x07), e = KeyUsage(rawValue: 0x08), f = KeyUsage(rawValue: 0x09)
  public static let g = KeyUsage(rawValue: 0x0a), h = KeyUsage(rawValue: 0x0b), i = KeyUsage(rawValue: 0x0c)
  public static let j = KeyUsage(rawValue: 0x0d), k = KeyUsage(rawValue: 0x0e), l = KeyUsage(rawValue: 0x0f)
  public static let m = KeyUsage(rawValue: 0x10), n = KeyUsage(rawValue: 0x11), o = KeyUsage(rawValue: 0x12)
  public static let p = KeyUsage(rawValue: 0x13), q = KeyUsage(rawValue: 0x14), r = KeyUsage(rawValue: 0x15)
  public static let s = KeyUsage(rawValue: 0x16), t = KeyUsage(rawValue: 0x17), u = KeyUsage(rawValue: 0x18)
  public static let v = KeyUsage(rawValue: 0x19), w = KeyUsage(rawValue: 0x1a), x = KeyUsage(rawValue: 0x1b)
  public static let y = KeyUsage(rawValue: 0x1c), z = KeyUsage(rawValue: 0x1d)
  public static let digit1 = KeyUsage(rawValue: 0x1e), digit2 = KeyUsage(rawValue: 0x1f), digit3 = KeyUsage(rawValue: 0x20)
  public static let digit4 = KeyUsage(rawValue: 0x21), digit5 = KeyUsage(rawValue: 0x22), digit6 = KeyUsage(rawValue: 0x23)
  public static let digit7 = KeyUsage(rawValue: 0x24), digit8 = KeyUsage(rawValue: 0x25), digit9 = KeyUsage(rawValue: 0x26)
  public static let digit0 = KeyUsage(rawValue: 0x27)
  public static let enter = KeyUsage(rawValue: 0x28), escape = KeyUsage(rawValue: 0x29)
  public static let backspace = KeyUsage(rawValue: 0x2a), tab = KeyUsage(rawValue: 0x2b), space = KeyUsage(rawValue: 0x2c)
  public static let minus = KeyUsage(rawValue: 0x2d), equal = KeyUsage(rawValue: 0x2e)
  public static let leftBracket = KeyUsage(rawValue: 0x2f), rightBracket = KeyUsage(rawValue: 0x30)
  public static let backslash = KeyUsage(rawValue: 0x31), nonUSHash = KeyUsage(rawValue: 0x32)
  public static let semicolon = KeyUsage(rawValue: 0x33), apostrophe = KeyUsage(rawValue: 0x34)
  public static let grave = KeyUsage(rawValue: 0x35), comma = KeyUsage(rawValue: 0x36), period = KeyUsage(rawValue: 0x37)
  public static let slash = KeyUsage(rawValue: 0x38), capsLock = KeyUsage(rawValue: 0x39)
  public static let f1 = KeyUsage(rawValue: 0x3a), f2 = KeyUsage(rawValue: 0x3b), f3 = KeyUsage(rawValue: 0x3c)
  public static let f4 = KeyUsage(rawValue: 0x3d), f5 = KeyUsage(rawValue: 0x3e), f6 = KeyUsage(rawValue: 0x3f)
  public static let f7 = KeyUsage(rawValue: 0x40), f8 = KeyUsage(rawValue: 0x41), f9 = KeyUsage(rawValue: 0x42)
  public static let f10 = KeyUsage(rawValue: 0x43), f11 = KeyUsage(rawValue: 0x44), f12 = KeyUsage(rawValue: 0x45)
  public static let printScreen = KeyUsage(rawValue: 0x46), scrollLock = KeyUsage(rawValue: 0x47)
  public static let pause = KeyUsage(rawValue: 0x48), insert = KeyUsage(rawValue: 0x49), home = KeyUsage(rawValue: 0x4a)
  public static let pageUp = KeyUsage(rawValue: 0x4b), delete = KeyUsage(rawValue: 0x4c), end = KeyUsage(rawValue: 0x4d)
  public static let pageDown = KeyUsage(rawValue: 0x4e), right = KeyUsage(rawValue: 0x4f), left = KeyUsage(rawValue: 0x50)
  public static let down = KeyUsage(rawValue: 0x51), up = KeyUsage(rawValue: 0x52), numLock = KeyUsage(rawValue: 0x53)
  public static let keypadSlash = KeyUsage(rawValue: 0x54), keypadAsterisk = KeyUsage(rawValue: 0x55)
  public static let keypadMinus = KeyUsage(rawValue: 0x56), keypadPlus = KeyUsage(rawValue: 0x57)
  public static let keypadEnter = KeyUsage(rawValue: 0x58)
  public static let keypad1 = KeyUsage(rawValue: 0x59), keypad2 = KeyUsage(rawValue: 0x5a), keypad3 = KeyUsage(rawValue: 0x5b)
  public static let keypad4 = KeyUsage(rawValue: 0x5c), keypad5 = KeyUsage(rawValue: 0x5d), keypad6 = KeyUsage(rawValue: 0x5e)
  public static let keypad7 = KeyUsage(rawValue: 0x5f), keypad8 = KeyUsage(rawValue: 0x60), keypad9 = KeyUsage(rawValue: 0x61)
  public static let keypad0 = KeyUsage(rawValue: 0x62), keypadPeriod = KeyUsage(rawValue: 0x63)
  public static let nonUSBackslash = KeyUsage(rawValue: 0x64), application = KeyUsage(rawValue: 0x65)
  public static let power = KeyUsage(rawValue: 0x66), keypadEqual = KeyUsage(rawValue: 0x67)
  public static let f13 = KeyUsage(rawValue: 0x68), f14 = KeyUsage(rawValue: 0x69), f15 = KeyUsage(rawValue: 0x6a)
  public static let f16 = KeyUsage(rawValue: 0x6b), f17 = KeyUsage(rawValue: 0x6c), f18 = KeyUsage(rawValue: 0x6d)
  public static let f19 = KeyUsage(rawValue: 0x6e), f20 = KeyUsage(rawValue: 0x6f), f21 = KeyUsage(rawValue: 0x70)
  public static let f22 = KeyUsage(rawValue: 0x71), f23 = KeyUsage(rawValue: 0x72), f24 = KeyUsage(rawValue: 0x73)
  public static let mute = KeyUsage(rawValue: 0x7f), volumeUp = KeyUsage(rawValue: 0x80)
  public static let volumeDown = KeyUsage(rawValue: 0x81), keypadComma = KeyUsage(rawValue: 0x85)
  public static let leftControl = KeyUsage(rawValue: 0xe0), leftShift = KeyUsage(rawValue: 0xe1)
  public static let leftAlt = KeyUsage(rawValue: 0xe2), leftSuper = KeyUsage(rawValue: 0xe3)
  public static let rightControl = KeyUsage(rawValue: 0xe4), rightShift = KeyUsage(rawValue: 0xe5)
  public static let rightAlt = KeyUsage(rawValue: 0xe6), rightSuper = KeyUsage(rawValue: 0xe7)

  /// Not a key on the keyboard page: an evdev code the table doesn't map.
  public static let unknown = KeyUsage(rawValue: 0)

  /// The usage of a Linux evdev keycode (KEY_*), or `.unknown`.
  public init(evdev code: UInt32) {
    self = code < UInt32(evdevToUsage.count) ? KeyUsage(rawValue: evdevToUsage[Int(code)]) : .unknown
  }

  /// Whether this is a modifier key (the keyboard page's 0xE0–0xE7).
  public var isModifier: Bool { rawValue >= 0xe0 && rawValue <= 0xe7 }
}

/// evdev keycode → HID usage, indexed by keycode; 0 where there's no key.
/// Pairs from input-event-codes.h (KEY_*) and the HID keyboard page, by name.
let evdevToUsage: [UInt16] = {
  let pairs: [(UInt32, UInt16)] = [
    (1, 0x29),  // ESC
    (2, 0x1e), (3, 0x1f), (4, 0x20), (5, 0x21), (6, 0x22), (7, 0x23), (8, 0x24), (9, 0x25), (10, 0x26), (11, 0x27),  // 1–9, 0
    (12, 0x2d), (13, 0x2e), (14, 0x2a), (15, 0x2b),  // MINUS, EQUAL, BACKSPACE, TAB
    (16, 0x14), (17, 0x1a), (18, 0x08), (19, 0x15), (20, 0x17), (21, 0x1c), (22, 0x18), (23, 0x0c), (24, 0x12), (25, 0x13),  // Q–P
    (26, 0x2f), (27, 0x30), (28, 0x28), (29, 0xe0),  // LEFTBRACE, RIGHTBRACE, ENTER, LEFTCTRL
    (30, 0x04), (31, 0x16), (32, 0x07), (33, 0x09), (34, 0x0a), (35, 0x0b), (36, 0x0d), (37, 0x0e), (38, 0x0f),  // A–L
    (39, 0x33), (40, 0x34), (41, 0x35), (42, 0xe1), (43, 0x31),  // SEMICOLON, APOSTROPHE, GRAVE, LEFTSHIFT, BACKSLASH
    (44, 0x1d), (45, 0x1b), (46, 0x06), (47, 0x19), (48, 0x05), (49, 0x11), (50, 0x10),  // Z–M
    (51, 0x36), (52, 0x37), (53, 0x38), (54, 0xe5), (55, 0x55), (56, 0xe2), (57, 0x2c), (58, 0x39),
    (59, 0x3a), (60, 0x3b), (61, 0x3c), (62, 0x3d), (63, 0x3e), (64, 0x3f), (65, 0x40), (66, 0x41), (67, 0x42), (68, 0x43),  // F1–F10
    (69, 0x53), (70, 0x47),  // NUMLOCK, SCROLLLOCK
    (71, 0x5f), (72, 0x60), (73, 0x61), (74, 0x56), (75, 0x5c), (76, 0x5d), (77, 0x5e), (78, 0x57),  // KP7–KP6, KPMINUS, KPPLUS
    (79, 0x59), (80, 0x5a), (81, 0x5b), (82, 0x62), (83, 0x63),  // KP1–KP3, KP0, KPDOT
    (86, 0x64), (87, 0x44), (88, 0x45),  // 102ND, F11, F12
    (96, 0x58), (97, 0xe4), (98, 0x54), (99, 0x46), (100, 0xe6),  // KPENTER, RIGHTCTRL, KPSLASH, SYSRQ, RIGHTALT
    (102, 0x4a), (103, 0x52), (104, 0x4b), (105, 0x50), (106, 0x4f), (107, 0x4d), (108, 0x51), (109, 0x4e),  // HOME–PAGEDOWN
    (110, 0x49), (111, 0x4c), (113, 0x7f), (114, 0x81), (115, 0x80), (116, 0x66), (117, 0x67), (119, 0x48),
    (121, 0x85), (125, 0xe3), (126, 0xe7), (127, 0x65),  // KPCOMMA, LEFTMETA, RIGHTMETA, COMPOSE
    (183, 0x68), (184, 0x69), (185, 0x6a), (186, 0x6b), (187, 0x6c), (188, 0x6d),  // F13–F18
    (189, 0x6e), (190, 0x6f), (191, 0x70), (192, 0x71), (193, 0x72), (194, 0x73),  // F19–F24
  ]
  var table = [UInt16](repeating: 0, count: 195)
  for (code, usage) in pairs { table[Int(code)] = usage }
  return table
}()
