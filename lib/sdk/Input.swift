// SPDX-License-Identifier: BSD-3-Clause

// Input events (sdk.md §2, §6): keys by HID usage, pointer motion and
// buttons, and the wheel. Hosted, they come from a Wayland seat; InputState
// turns its events into the SDK's, and is tested with synthetic ones.

import Glibc
import Wayland

public struct Modifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = Modifiers(rawValue: 1 << 0)
  public static let control = Modifiers(rawValue: 1 << 1)
  public static let alt = Modifiers(rawValue: 1 << 2)
  public static let `super` = Modifiers(rawValue: 1 << 3)
  public static let capsLock = Modifiers(rawValue: 1 << 4)
  public static let numLock = Modifiers(rawValue: 1 << 5)
}

/// A key press or release.
public struct Key: Sendable, Equatable {
  /// The physical key, whatever the layout.
  public var usage: KeyUsage
  /// The platform's own code for it (Linux evdev, hosted).
  public var scancode: UInt32
  public var modifiers: Modifiers
  /// A repeat of a key held down, not a new press.
  public var isRepeat: Bool
}

public enum PointerButton: Sendable, Equatable {
  case left, right, middle, back, forward
  case other(UInt32)

  /// From a Linux evdev button code (BTN_*).
  init(evdev code: UInt32) {
    switch code {
    case 0x110: self = .left
    case 0x111: self = .right
    case 0x112: self = .middle
    case 0x113: self = .back  // BTN_SIDE
    case 0x114: self = .forward  // BTN_EXTRA
    default: self = .other(code)
    }
  }
}

public struct Pointer: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case enter, leave, motion
    case down(PointerButton)
    case up(PointerButton)
  }
  public var action: Action
  /// The position in the window, in logical points.
  public var x: Double
  public var y: Double
  public var modifiers: Modifiers
}

public struct Wheel: Sendable, Equatable {
  /// Scroll distance in logical points (positive: right, down).
  public var dx: Double
  public var dy: Double
  /// Wheel notches, where the device has them (1 per detent; fractions on
  /// high-resolution wheels).
  public var stepsX: Double
  public var stepsY: Double
  public var modifiers: Modifiers
}

/// Turns a Wayland seat's events into the SDK's.
struct InputState {
  enum Output: Equatable {
    case event(Event.Payload, WlSurface?)
    case startRepeat(Key, delay: Duration, interval: Duration)
    case stopRepeat
  }

  var keyboardFocus: WlSurface?
  var pointerFocus: WlSurface?
  var heldModifiers: [KeyUsage: Bool] = [:]
  var locks: Modifiers = []
  var x = 0.0, y = 0.0
  var wheel = Wheel(dx: 0, dy: 0, stepsX: 0, stepsY: 0, modifiers: [])
  var wheelPending = false
  var repeatRate: Int32 = 25  // per second; 0 disables
  var repeatDelay: Int32 = 600  // ms
  var repeating: KeyUsage?
  /// Below version 5 a seat has no `frame` event to end a group with.
  var pointerFrames = true

  var modifiers: Modifiers {
    var m = locks
    func held(_ a: KeyUsage, _ b: KeyUsage) -> Bool { heldModifiers[a] == true || heldModifiers[b] == true }
    if held(.leftShift, .rightShift) { m.insert(.shift) }
    if held(.leftControl, .rightControl) { m.insert(.control) }
    if held(.leftAlt, .rightAlt) { m.insert(.alt) }
    if held(.leftSuper, .rightSuper) { m.insert(.super) }
    return m
  }

  mutating func handle(_ e: WaylandEvent) -> [Output] {
    switch e {
    // Keyboard.
    case .wlKeyboard(_, .keymap(_, let fd, _)):
      close(fd)  // the layout's text arrives with IME work; usages need no keymap
      return []
    case .wlKeyboard(_, .enter(_, let surface, let keys)):
      keyboardFocus = surface
      heldModifiers = [:]
      for k in stride(from: 0, to: keys.count - 3, by: 4) {
        let code = UInt32(keys[k]) | UInt32(keys[k + 1]) << 8 | UInt32(keys[k + 2]) << 16 | UInt32(keys[k + 3]) << 24
        let usage = KeyUsage(evdev: code)
        if usage.isModifier { heldModifiers[usage] = true }
      }
      return []
    case .wlKeyboard(_, .leave(_, _)):
      keyboardFocus = nil
      heldModifiers = [:]
      let stop = repeating != nil
      repeating = nil
      return stop ? [.stopRepeat] : []
    case .wlKeyboard(_, .key(_, _, let code, let state)):
      let usage = KeyUsage(evdev: code)
      let down = state != .released
      if usage.isModifier { heldModifiers[usage] = down }
      let key = Key(usage: usage, scancode: code, modifiers: modifiers, isRepeat: state == .repeated)
      var out: [Output] = [.event(down ? .keyDown(key) : .keyUp(key), keyboardFocus)]
      if state == .pressed && !usage.isModifier && repeatRate > 0 {
        repeating = usage
        out.append(.startRepeat(key, delay: .milliseconds(Int64(repeatDelay)), interval: .milliseconds(Int64(1000 / repeatRate))))
      } else if !down && repeating == usage {
        repeating = nil
        out.append(.stopRepeat)
      }
      return out
    case .wlKeyboard(_, .modifiers(_, _, _, let locked, _)):
      // Lock and Mod2 are bits 1 and 4 in the standard evdev keymaps.
      locks = []
      if locked & (1 << 1) != 0 { locks.insert(.capsLock) }
      if locked & (1 << 4) != 0 { locks.insert(.numLock) }
      return []
    case .wlKeyboard(_, .repeatInfo(let rate, let delay)):
      repeatRate = max(0, rate)
      repeatDelay = max(0, delay)
      return []

    // Pointer.
    case .wlPointer(_, .enter(_, let surface, let sx, let sy)):
      pointerFocus = surface
      x = sx.double
      y = sy.double
      return [pointer(.enter)]
    case .wlPointer(_, .leave(_, let surface)):
      let out = [Output.event(.pointer(Pointer(action: .leave, x: x, y: y, modifiers: modifiers)), surface)]
      pointerFocus = nil
      return out
    case .wlPointer(_, .motion(_, let sx, let sy)):
      x = sx.double
      y = sy.double
      return [pointer(.motion)]
    case .wlPointer(_, .button(_, _, let button, let state)):
      let b = PointerButton(evdev: button)
      return [pointer(state == .pressed ? .down(b) : .up(b))]
    case .wlPointer(_, .axis(_, let axis, let value)):
      if axis == .verticalScroll { wheel.dy += value.double } else { wheel.dx += value.double }
      wheelPending = true
      return pointerFrames ? [] : flushWheel()
    case .wlPointer(_, .axisValue120(let axis, let value120)):
      if axis == .verticalScroll { wheel.stepsY += Double(value120) / 120 } else { wheel.stepsX += Double(value120) / 120 }
      wheelPending = true
      return []
    case .wlPointer(_, .axisDiscrete(let axis, let discrete)):
      if axis == .verticalScroll { wheel.stepsY += Double(discrete) } else { wheel.stepsX += Double(discrete) }
      wheelPending = true
      return []
    case .wlPointer(_, .frame):
      return flushWheel()
    default:
      return []
    }
  }

  func pointer(_ action: Pointer.Action) -> Output {
    .event(.pointer(Pointer(action: action, x: x, y: y, modifiers: modifiers)), pointerFocus)
  }

  mutating func flushWheel() -> [Output] {
    guard wheelPending else { return [] }
    var w = wheel
    w.modifiers = modifiers
    wheel = Wheel(dx: 0, dy: 0, stepsX: 0, stepsY: 0, modifiers: [])
    wheelPending = false
    return [.event(.wheel(w), pointerFocus)]
  }
}
