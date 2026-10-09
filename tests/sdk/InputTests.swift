// SPDX-License-Identifier: BSD-3-Clause

// InputState, driven by synthetic Wayland seat events.

import Testing
import Wayland

@testable import Todhchai

let kb = WlKeyboard(id: 10)
let mouse = WlPointer(id: 11)
let surface = WlSurface(id: 20)

func keyEvent(_ code: UInt32, _ state: WlKeyboard.KeyState) -> WaylandEvent {
  .wlKeyboard(kb, .key(serial: 1, time: 0, key: code, state: state))
}

func payloads(_ outputs: [InputState.Output]) -> [Event.Payload] {
  outputs.compactMap { if case .event(let p, _) = $0 { p } else { nil } }
}

@Test func keysAreHIDUsagesWithModifiersTrackedFromKeys() {
  var input = InputState()
  _ = input.handle(.wlKeyboard(kb, .enter(serial: 1, surface: surface, keys: [])))
  _ = input.handle(keyEvent(42, .pressed))  // KEY_LEFTSHIFT
  let out = input.handle(keyEvent(17, .pressed))  // KEY_W
  guard case .keyDown(let key) = payloads(out).first else {
    Issue.record("expected a key down")
    return
  }
  #expect(key.usage == .w && key.scancode == 17 && key.modifiers == [.shift] && !key.isRepeat)
  #expect(out.contains { if case .event(_, let s) = $0 { s == surface } else { false } })
  _ = input.handle(keyEvent(42, .released))
  #expect(input.modifiers.isEmpty)
}

@Test func locksComeFromTheCompositorsLockedMask() {
  var input = InputState()
  _ = input.handle(.wlKeyboard(kb, .modifiers(serial: 1, modsDepressed: 0, modsLatched: 0, modsLocked: 0b1_0010, group: 0)))
  #expect(input.modifiers == [.capsLock, .numLock])
}

@Test func heldKeysRepeatAndStopOnRelease() {
  var input = InputState()
  _ = input.handle(.wlKeyboard(kb, .repeatInfo(rate: 40, delay: 300)))
  let down = input.handle(keyEvent(57, .pressed))  // KEY_SPACE
  #expect(down.contains(.startRepeat(Key(usage: .space, scancode: 57, modifiers: [], isRepeat: false),
                                     delay: .milliseconds(300), interval: .milliseconds(25))))
  #expect(input.handle(keyEvent(57, .released)).contains(.stopRepeat))
  // Modifiers don't repeat; a compositor-side repeat (state 2) is a repeat.
  #expect(!input.handle(keyEvent(29, .pressed)).contains { if case .startRepeat = $0 { true } else { false } })
  guard case .keyDown(let r) = payloads(input.handle(keyEvent(30, .repeated))).first else {
    Issue.record("expected a repeated key down")
    return
  }
  #expect(r.isRepeat && r.usage == .a)
}

@Test func leavingStopsRepeatAndForgetsModifiers() {
  var input = InputState()
  _ = input.handle(keyEvent(29, .pressed))  // KEY_LEFTCTRL
  _ = input.handle(keyEvent(30, .pressed))
  let out = input.handle(.wlKeyboard(kb, .leave(serial: 1, surface: surface)))
  #expect(out.contains(.stopRepeat) && input.modifiers.isEmpty)
}

@Test func enterTakesTheModifiersAlreadyHeld() {
  var input = InputState()
  _ = input.handle(.wlKeyboard(kb, .enter(serial: 1, surface: surface, keys: [29, 0, 0, 0])))  // LEFTCTRL held
  #expect(input.modifiers == [.control])
}

@Test func pointerMotionButtonsAndWheelFrames() {
  var input = InputState()
  let enter = payloads(input.handle(.wlPointer(mouse, .enter(serial: 1, surface: surface, surfaceX: WaylandFixed(10.5), surfaceY: WaylandFixed(20)))))
  #expect(enter == [.pointer(Pointer(action: .enter, x: 10.5, y: 20, modifiers: []))])
  let down = payloads(input.handle(.wlPointer(mouse, .button(serial: 2, time: 0, button: 0x110, state: .pressed))))
  #expect(down == [.pointer(Pointer(action: .down(.left), x: 10.5, y: 20, modifiers: []))])
  // Axis events gather until the frame that ends them.
  #expect(input.handle(.wlPointer(mouse, .axis(time: 0, axis: .verticalScroll, value: WaylandFixed(15)))).isEmpty)
  #expect(input.handle(.wlPointer(mouse, .axisValue120(axis: .verticalScroll, value120: 60))).isEmpty)
  let frame = payloads(input.handle(.wlPointer(mouse, .frame)))
  #expect(frame == [.wheel(Wheel(dx: 0, dy: 15, stepsX: 0, stepsY: 0.5, modifiers: []))])
  #expect(input.handle(.wlPointer(mouse, .frame)).isEmpty)  // nothing pending
}

@Test func evdevKeycodesMapByName() {
  #expect(KeyUsage(evdev: 1) == .escape && KeyUsage(evdev: 57) == .space && KeyUsage(evdev: 28) == .enter)
  #expect(KeyUsage(evdev: 30) == .a && KeyUsage(evdev: 44) == .z && KeyUsage(evdev: 11) == .digit0)
  #expect(KeyUsage(evdev: 103) == .up && KeyUsage(evdev: 125) == .leftSuper && KeyUsage(evdev: 194) == .f24)
  #expect(KeyUsage(evdev: 84) == .unknown && KeyUsage(evdev: 9999) == .unknown)
  // No two keycodes share a usage.
  let used = evdevToUsage.filter { $0 != 0 }
  #expect(Set(used).count == used.count)
}
