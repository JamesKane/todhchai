// SPDX-License-Identifier: BSD-3-Clause

// The mixer (sdk.md §7): voices playing sounds, mixed on the real-time
// thread. `play` and `stop` may be called from any thread: commands cross
// to the audio thread through a lock-free single-consumer queue, and the
// real-time side allocates nothing, locks nothing, and counts no
// references (its render is @_noAllocation).

import Synchronization

public struct VoiceID: Hashable, Sendable { public var raw: UInt32 }

struct Voice {
  var samples: UnsafePointer<Float>?
  var channels: Int
  var frames: Int
  var position: Int
  var gainLeft: Float
  var gainRight: Float
  var looping: Bool
  var id: UInt32
}

enum MixerCommand {
  case play(Voice)
  case stop(UInt32)
  case stopAll
}

/// The state both sides share, in memory allocated once and never freed.
struct MixerCore {
  static let voiceCount = 64
  static let queueCapacity = 256  // a power of two

  let voices: UnsafeMutableBufferPointer<Voice>
  let queue: UnsafeMutableBufferPointer<MixerCommand>
  let head: UnsafeMutablePointer<Atomic<Int>>  // commands written (producer)
  let tail: UnsafeMutablePointer<Atomic<Int>>  // commands taken (the audio thread)
  let playing: UnsafeMutablePointer<Atomic<Int>>

  init() {
    voices = .allocate(capacity: Self.voiceCount)
    voices.initialize(repeating: Voice(samples: nil, channels: 0, frames: 0, position: 0, gainLeft: 0, gainRight: 0,
                                       looping: false, id: 0))
    queue = .allocate(capacity: Self.queueCapacity)
    queue.initialize(repeating: .stopAll)
    head = .allocate(capacity: 1)
    head.initialize(to: Atomic(0))
    tail = .allocate(capacity: 1)
    tail.initialize(to: Atomic(0))
    playing = .allocate(capacity: 1)
    playing.initialize(to: Atomic(0))
  }

  /// Queues a command (producer side; callers serialize). False if full.
  func push(_ c: MixerCommand) -> Bool {
    let h = head.pointee.load(ordering: .relaxed)
    guard h - tail.pointee.load(ordering: .acquiring) < Self.queueCapacity else { return false }
    queue[h & (Self.queueCapacity - 1)] = c
    head.pointee.store(h + 1, ordering: .releasing)
    return true
  }

  /// Mixes every voice into `out` (interleaved, `channels` per frame),
  /// adding to what's there. Runs on the audio thread.
  @_noAllocation
  func render(into out: UnsafeMutableBufferPointer<Float>, channels: Int) {
    // Take queued commands.
    var t = tail.pointee.load(ordering: .relaxed)
    let h = head.pointee.load(ordering: .acquiring)
    while t != h {
      switch queue[t & (Self.queueCapacity - 1)] {
      case .play(let v):
        var slot = 0
        while slot < voices.count && voices[slot].samples != nil { slot += 1 }
        if slot < voices.count { voices[slot] = v }  // all busy: the newest is dropped
      case .stop(let id):
        for i in 0..<voices.count where voices[i].id == id { voices[i].samples = nil }
      case .stopAll:
        for i in 0..<voices.count { voices[i].samples = nil }
      }
      t += 1
    }
    tail.pointee.store(t, ordering: .releasing)

    let frames = out.count / max(channels, 1)
    var active = 0
    for v in 0..<voices.count {
      guard let samples = voices[v].samples else { continue }
      let vc = voices[v].channels
      for f in 0..<frames {
        if voices[v].position >= voices[v].frames {
          if voices[v].looping && voices[v].frames > 0 {
            voices[v].position = 0
          } else {
            voices[v].samples = nil
            break
          }
        }
        let base = voices[v].position * vc
        let left = samples[base], right = vc > 1 ? samples[base + 1] : left
        if channels == 1 {
          out[f] += (left * voices[v].gainLeft + right * voices[v].gainRight) * 0.5
        } else {
          out[f * channels] += left * voices[v].gainLeft
          out[f * channels + 1] += right * voices[v].gainRight
        }
        voices[v].position += 1
      }
      if voices[v].samples != nil { active += 1 }  // still playing after this render
    }
    playing.pointee.store(active, ordering: .relaxed)
  }
}

/// Plays sounds (sdk.md §7: `Mixer.shared.play(sound)`).
public final class Mixer: @unchecked Sendable {
  let core = MixerCore()
  let producer = Mutex()
  var nextID: UInt32 = 1
  var stream: AudioStream?
  let opensOutput: Bool

  /// The process's mixer. It opens the default audio output the first
  /// time it plays something.
  public static let shared = Mixer()

  /// A mixer. With `opensOutput` false it never opens a stream; render it
  /// yourself through `renderer`, from one thread only.
  public init(opensOutput: Bool = true) { self.opensOutput = opensOutput }

  /// Plays `sound`. `pan` is −1 (left) to 1 (right). Returns nil if the
  /// command queue is full or no audio output can be opened.
  @discardableResult
  public func play(_ sound: Sound, gain: Float = 1, pan: Float = 0, loop: Bool = false) -> VoiceID? {
    if stream == nil && opensOutput {
      stream = try? AudioStream.open(.f32(channels: 2, rate: sound.rate), periodFrames: 256,
                                     renderer: MixerRenderer(core: core))
    }
    return producer.withLock { () -> VoiceID? in
      let id = nextID
      nextID &+= 1
      let p = max(-1, min(1, pan))
      let voice = Voice(samples: sound.samples, channels: sound.channels, frames: sound.frames, position: 0,
                        gainLeft: gain * min(1, 1 - p), gainRight: gain * min(1, 1 + p), looping: loop, id: id)
      return core.push(.play(voice)) ? VoiceID(raw: id) : nil
    }
  }

  public func stop(_ voice: VoiceID) { producer.withLock { _ = core.push(.stop(voice.raw)) } }
  public func stopAll() { producer.withLock { _ = core.push(.stopAll) } }

  /// Voices still playing after the last render.
  public var playing: Int { core.playing.pointee.load(ordering: .relaxed) }

  /// A renderer that plays this mixer, for a stream of your own.
  public var renderer: MixerRenderer { MixerRenderer(core: core) }
}

/// The mixer as an `AudioRenderer`.
public struct MixerRenderer: AudioRenderer {
  let core: MixerCore
  public static var _realtimeChecked: AudioRealtimeChecked { .byTheCompiler }

  @_noAllocation
  public mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime) {
    core.render(into: out, channels: 2)
  }
}
