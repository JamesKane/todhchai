// SPDX-License-Identifier: BSD-3-Clause

// minimal, in Swift (sdk.md §3): a window whose color cycles, a beep on
// space, escape or closing quits. minimal.c, .zig and .odin are the same
// program through the C ABI.
//
// For td bench: TODHCHAI_MINIMAL_FRAMES=N stops after N frames; with
// TODHCHAI_MINIMAL_IDLE=S as well, it then stops asking for frames,
// settles, and waits S seconds between the trace marks "idle" and
// "idle.end", where the loop should never wake.

import Glibc
import Todhchai
import Trace

let frameLimit = getenv("TODHCHAI_MINIMAL_FRAMES").flatMap { Int(String(cString: $0)) }
let idleSeconds = getenv("TODHCHAI_MINIMAL_IDLE").flatMap { Int64(String(cString: $0)) }
var drawn = 0

var loop = try Loop()
let win = try loop.openWindow("minimal (Swift)", width: 640, height: 360)
let beep = try? Sound.load("examples/minimal/beep.wav")
var seq: UInt64 = 0
loop.requestFrame(win)

main: while true {
  for e in loop.wait() {
    switch e.payload {
    case .configure(let c): seq = c.configSeq
    case .frame(let f):
      if let px = loop.cpuSurface(win) {
        let t = UInt32(truncatingIfNeeded: f.target.ns / 16_000_000)
        px.fill((t &* 3 & 0xff) << 16 | (t &* 5 & 0xff) << 8 | (t &* 7 & 0xff))
        try? loop.present(win, px, configSeq: seq)
        drawn += 1
        if drawn == frameLimit { break main }
      }
      loop.requestFrame(win)
    case .keyDown(let k) where k.usage == .space: if let beep { Mixer.shared.play(beep) }
    case .keyDown(let k) where k.usage == .escape: break main
    case .close, .quit: break main
    default: break
    }
  }
}

if let idleSeconds {
  // Let the last frame's callback, feedback and buffer release arrive.
  _ = loop.wait(until: .now + .milliseconds(500))
  while !loop.poll().isEmpty {}
  Trace.mark("idle")
  let end = Deadline.now + .seconds(idleSeconds)
  while Deadline.now < end { _ = loop.wait(until: end) }
  Trace.mark("idle.end")
}
loop.closeWindow(win)
