// SPDX-License-Identifier: BSD-3-Clause

import Glibc
import Synchronization
import Testing

@testable import Todhchai

/// A renderer as an app writes one: the macro has the compiler check that
/// `render` allocates nothing and takes no locks.
@AudioRenderer
struct Sine {
  var phase: Float = 0
  let calls: UnsafeMutablePointer<Atomic<Int>>

  mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
    for i in out.indices {
      out[i] = phase
      phase += 0.01
    }
    calls.pointee.add(1, ordering: .relaxed)
  }
}

@Test func aCheckedRendererRunsOnTheClock() throws {
  let calls = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
  calls.initialize(to: Atomic(0))
  let stream = try AudioStream.open(.f32(channels: 2, rate: 48_000), periodFrames: 128,
                                    renderer: Sine(calls: calls), device: .clock)
  #expect(stream.contract.period == 128 && stream.contract.device == "clock")
  sleep(until: .now + .milliseconds(200))
  stream.stop()
  // 200 ms at 48 kHz in periods of 128 frames is 75 periods. The machine
  // may be busy, so only roughly.
  #expect(stream.cycles > 40 && stream.cycles < 90)
  #expect(calls.pointee.load(ordering: .relaxed) == stream.cycles)
}

/// A WAV file in memory: 16-bit PCM.
func wav16(_ samples: [Int16], channels: Int, rate: Int) -> [UInt8] {
  func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
  func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
  let data = samples.flatMap { le16(Int($0)) }
  let fmt = le16(1) + le16(channels) + le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16)
  let body = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(data.count) + data
  return Array("RIFF".utf8) + le32(body.count) + body
}

@Test func wavFilesDecodeAndResample() throws {
  let s = try Sound.decode(wav16([0, 16384, -32768, 32767], channels: 2, rate: 48_000))
  #expect(s.channels == 2 && s.frames == 2 && s.rate == 48_000)
  #expect(s.samples[1] == 0.5 && s.samples[2] == -1)
  let up = try Sound.decode(wav16([Int16](repeating: 1000, count: 441), channels: 1, rate: 44_100), rate: 48_000)
  #expect(up.frames == 480)
  #expect(throws: SoundError.self) { try Sound.decode(Array("RIFF....WAVX".utf8)) }
}

@Test func theMixerPansLoopsStopsAndEnds() throws {
  let mixer = Mixer(opensOutput: false)
  var renderer = mixer.renderer
  let one = Sound.make([Float](repeating: 1, count: 4), channels: 1, rate: 48_000)  // 4 frames
  var out = [Float](repeating: 0, count: 16)  // 8 stereo frames
  let time = AudioTime(position: 0, playsAt: .now)

  _ = mixer.play(one, gain: 0.5, pan: -1)
  out.withUnsafeMutableBufferPointer { renderer.render(into: $0, time: time) }
  // Left at 0.5 for the sound's 4 frames, right silent, then nothing.
  #expect(out[0] == 0.5 && out[1] == 0 && out[6] == 0.5 && out[8] == 0)
  #expect(mixer.playing == 0)  // the voice ended within the render

  let looping = mixer.play(one, loop: true)
  out = [Float](repeating: 0, count: 16)
  out.withUnsafeMutableBufferPointer { renderer.render(into: $0, time: time) }
  #expect(out.allSatisfy { $0 == 1 } && mixer.playing == 1)
  mixer.stop(try #require(looping))
  out = [Float](repeating: 0, count: 16)
  out.withUnsafeMutableBufferPointer { renderer.render(into: $0, time: time) }
  #expect(out.allSatisfy { $0 == 0 } && mixer.playing == 0)
}

@Test func aFullCommandQueueRefusesRatherThanBlocks() {
  let mixer = Mixer(opensOutput: false)
  let s = Sound.make([0, 0], channels: 1, rate: 48_000)
  var accepted = 0
  for _ in 0..<(MixerCore.queueCapacity + 10) where mixer.play(s) != nil { accepted += 1 }
  #expect(accepted == MixerCore.queueCapacity)
}

/// A silent renderer through the desktop's PipeWire, via AudioStream.
@Test(.enabled(if: getenv("TODHCHAI_LIVE_AUDIO") != nil))
func aStreamPlaysThroughPipeWire() throws {
  let calls = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
  calls.initialize(to: Atomic(0))
  let stream = try AudioStream.open(.f32(channels: 2, rate: 48_000), periodFrames: 128, renderer: Silence(calls: calls))
  sleep(until: .now + .milliseconds(500))
  stream.stop()
  #expect(stream.contract.device == "pipewire" && stream.contract.period == 128)
  #expect(stream.cycles > 150 && stream.cycles == calls.pointee.load(ordering: .relaxed))
  #expect(stream.underruns == 0)
}

@AudioRenderer
struct Silence {
  let calls: UnsafeMutablePointer<Atomic<Int>>
  mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
    calls.pointee.add(1, ordering: .relaxed)
  }
}
