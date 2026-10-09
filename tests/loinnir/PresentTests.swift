// SPDX-License-Identifier: BSD-3-Clause

// GPU frames in a real window, through dmabuf. Opens a window for about a
// second, so it runs only with TODHCHAI_LIVE_WINDOWS=1.

import Glibc
import Loinnir
import Testing
import Todhchai

@Test(.enabled(if: getenv("TODHCHAI_LIVE_WINDOWS") != nil))
func gpuFramesReachTheGlassThroughDmabuf() throws {
  var loop = try Loop()
  let win = try loop.openWindow("todhchai-gpu-test", width: 320, height: 200)
  let gpu = try Loinnir.open(window: win, loop: &loop)
  var config: Configure?
  var frames: [Frame] = []
  var drawn = 0
  let giveUp = Deadline.now + .seconds(5)
  loop.requestFrame(win)
  while frames.count < 60 && Deadline.now < giveUp {
    for e in loop.wait(until: giveUp) where e.window == win {
      switch e.payload {
      case .configure(let c): config = c
      case .frame(let f):
        frames.append(f)
        guard let c = config else { break }
        let t = Float(frames.count) / 60
        if try gpu.clear((t, 0.2, 1 - t, 1), loop: &loop, config: c) { drawn += 1 }
        loop.requestFrame(win)
      default: break
      }
    }
  }
  loop.closeWindow(win)
  #expect(frames.count == 60)
  #expect(drawn >= 55)
  #expect(frames.dropFirst(5).filter { $0.presentedAt != nil }.count >= 50)
}
