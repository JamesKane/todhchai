// SPDX-License-Identifier: BSD-3-Clause

// Windows on the desktop's compositor. These open a real window for about
// half a second, so they run only with TODHCHAI_LIVE_WINDOWS=1.

import Glibc
import Testing
import Todhchai

@Test(.enabled(if: getenv("TODHCHAI_LIVE_WINDOWS") != nil))
func aWindowConfiguresDrawsAndGetsPresentationTimes() throws {
  var loop = try Loop()
  let win = try loop.openWindow("todhchai-test", width: 320, height: 200)
  var config: Configure?
  var frames: [Frame] = []
  var staleRefused = false
  let giveUp = Deadline.now + .seconds(5)
  loop.requestFrame(win)
  while frames.count < 30 && Deadline.now < giveUp {
    for e in loop.wait(until: giveUp) where e.window == win {
      switch e.payload {
      case .configure(let c): config = c
      case .frame(let f):
        frames.append(f)
        guard let c = config, let surface = loop.cpuSurface(win) else { break }
        #expect(surface.width == c.pixelWidth && surface.height == c.pixelHeight)
        surface.fill(UInt32(frames.count * 8) << 8)
        if !staleRefused {
          // A buffer for a configuration that isn't current is refused.
          do throws(WindowError) {
            try loop.present(win, surface, configSeq: c.configSeq &+ 1)
          } catch {
            staleRefused = error == .staleConfig
          }
        } else {
          try loop.present(win, surface, configSeq: c.configSeq)
        }
        loop.requestFrame(win)
      default: break
      }
    }
  }
  loop.closeWindow(win)
  let c = try #require(config)
  #expect(c.width > 0 && c.height > 0 && c.scale >= 120)
  #expect(frames.count == 30)
  #expect(staleRefused)
  // Once frames are being presented, feedback says when they reached the glass.
  let timed = frames.dropFirst(5).filter { $0.presentedAt != nil && $0.refresh != nil }
  #expect(timed.count >= 20)
  if let f = timed.last, let refresh = f.refresh {
    #expect(f.target > f.presentedAt!)
    #expect(refresh > .milliseconds(2) && refresh < .milliseconds(50))
  }
}
