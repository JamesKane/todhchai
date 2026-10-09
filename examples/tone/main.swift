// SPDX-License-Identifier: BSD-3-Clause

// tone: one second of 440 Hz at −20 dB through the default output, then
// the stream's contract and underruns. A check you can hear.
//
//   swift build --product tone && .build/debug/tone
//
// The renderer can't call sinf: @AudioRenderer has the compiler reject
// any function it can't see into, which might lock or allocate. So the
// oscillator rotates a point around the circle by a step computed once.

import Glibc
import Todhchai

@AudioRenderer
struct Tone {
  var x: Float = 1, y: Float = 0  // the oscillator: a point on the unit circle
  let cosStep: Float, sinStep: Float

  init(hz: Float, rate: Float) {
    cosStep = cosf(2 * .pi * hz / rate)
    sinStep = sinf(2 * .pi * hz / rate)
  }

  mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
    var i = 0
    while i + 1 < out.count {
      let v = 0.1 * y  // −20 dB
      out[i] = v
      out[i + 1] = v
      (x, y) = (x * cosStep - y * sinStep, x * sinStep + y * cosStep)
      i += 2
    }
    // Keep the point on the circle as rounding drifts it.
    let scale = (3 - (x * x + y * y)) / 2
    x *= scale
    y *= scale
  }
}

let stream = try AudioStream.open(.f32(channels: 2, rate: 48_000), periodFrames: 128,
                                  renderer: Tone(hz: 440, rate: 48_000))
sleep(until: .now + .seconds(1))
stream.stop()
print("played on \(stream.contract.device): \(stream.contract.period) frames a period, \(stream.cycles) periods, \(stream.underruns) underruns")
