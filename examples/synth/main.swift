// SPDX-License-Identifier: BSD-3-Clause

// synth: an arpeggio over a drone, rendered at 128 frames a period
// (sdk.md §9). The renderer is an @AudioRenderer, so the compiler rejects
// allocation, locks and calls it can't see into in `render`; everything it
// needs (oscillator steps, the envelope's decay) is computed in `init`.
//
//   swift build --product synth && .build/debug/synth      (Ctrl-C stops)
//
// TODHCHAI_SYNTH_SECONDS=S stops after S seconds; TODHCHAI_SYNTH_GAIN sets
// the level (td bench uses 0). The trace marks "steady" and "steady.end"
// bracket the run after a second's warm-up.

import Glibc
import Todhchai
import Trace

let rate: Float = 48_000

@AudioRenderer
struct Synth {
  // The arpeggio: an A minor seventh over two octaves, eighth notes at 120 bpm.
  var cosSteps: InlineArray<8, Float>
  var sinSteps: InlineArray<8, Float>
  let noteFrames = 6_000
  let decay: Float
  let gain: Float
  let droneCos: Float, droneSin: Float

  var x: Float = 1, y: Float = 0  // the lead oscillator
  var dx: Float = 1, dy: Float = 0  // the drone
  var envelope: Float = 0
  var frame = 0
  var note = 0

  init(gain: Float) {
    let notes: [Float] = [220, 261.63, 329.63, 392, 440, 392, 329.63, 261.63]
    cosSteps = InlineArray(repeating: 0)
    sinSteps = InlineArray(repeating: 0)
    for i in 0..<8 {
      cosSteps[i] = cosf(2 * .pi * notes[i] / rate)
      sinSteps[i] = sinf(2 * .pi * notes[i] / rate)
    }
    decay = expf(-1 / (0.15 * rate))  // a 150 ms time constant
    droneCos = cosf(2 * .pi * 110 / rate)
    droneSin = sinf(2 * .pi * 110 / rate)
    self.gain = gain
  }

  mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
    var i = 0
    while i + 1 < out.count {
      if frame % noteFrames == 0 {
        note = (frame / noteFrames) % 8
        envelope = 1
      }
      let c = cosSteps[note], s = sinSteps[note]
      (x, y) = (x * c - y * s, x * s + y * c)
      (dx, dy) = (dx * droneCos - dy * droneSin, dx * droneSin + dy * droneCos)
      let v = gain * (0.6 * envelope * y + 0.25 * dy)
      out[i] = v
      out[i + 1] = v
      envelope *= decay
      frame += 1
      i += 2
    }
    // Keep both points on the circle as rounding drifts them.
    let k = (3 - (x * x + y * y)) / 2, kd = (3 - (dx * dx + dy * dy)) / 2
    x *= k
    y *= k
    dx *= kd
    dy *= kd
  }
}

let seconds = getenv("TODHCHAI_SYNTH_SECONDS").flatMap { Int64(String(cString: $0)) }
let gain = getenv("TODHCHAI_SYNTH_GAIN").flatMap { Float(String(cString: $0)) } ?? 0.2

var loop = try Loop()
let stream = try AudioStream.open(.f32(channels: 2, rate: Int(rate)), periodFrames: 128, renderer: Synth(gain: gain))
_ = loop.wait(until: .now + .seconds(1))  // warm-up: the graph settles on its period
let start = stream.underruns
Trace.mark("steady")
let end = seconds.map { Deadline.now + .seconds($0) }
run: while end.map({ Deadline.now < $0 }) ?? true {
  for e in loop.wait(until: end) {
    if case .quit = e.payload { break run }
  }
}
Trace.mark("steady.end")
let underruns = stream.underruns - start
stream.stop()
print("synth on \(stream.contract.device): \(stream.contract.period) frames a period, \(stream.cycles) periods, \(underruns) underruns; render thread: \(stream.admission)")
