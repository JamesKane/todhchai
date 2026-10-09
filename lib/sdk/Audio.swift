// SPDX-License-Identifier: BSD-3-Clause

// Audio streams (sdk.md §7). A stream pulls frames from a renderer on a
// real-time thread the SDK owns. The renderer's `render` is checked by the
// compiler for allocation and locks (@AudioRenderer), so a callback that
// could glitch fails to build instead.

import Glibc
import PipeWire
import Synchronization

/// Interleaved 32-bit float, `channels` per frame, at `rate` Hz.
public struct AudioFormat: Sendable, Equatable {
  public var channels: Int
  public var rate: Int
  public static func f32(channels: Int, rate: Int) -> AudioFormat { AudioFormat(channels: channels, rate: rate) }
}

/// When the frames a render call writes will play.
public struct AudioTime: Sendable {
  /// Frames rendered on this stream before this call.
  public var position: UInt64
  /// When the first of this call's frames reaches the speaker, as best known.
  public var playsAt: Deadline
}

/// What the stream actually got (sdk.md §7, the contract).
public struct AudioContract: Sendable, Equatable {
  public var format: AudioFormat
  /// Frames per render call.
  public var period: Int
  /// From a render call to its first frame being heard, end to end.
  public var latency: Duration
  /// Where the audio goes ("pipewire", "clock" for no device).
  public var device: String
}

/// The proof `@AudioRenderer` writes: the type's `render` is compiler-checked.
public enum AudioRealtimeChecked: Sendable { case byTheCompiler }

/// A source of audio, called on the real-time thread. Conform with the
/// `@AudioRenderer` macro, which has the compiler check `render`.
public protocol AudioRenderer: SendableMetatype {
  static var _realtimeChecked: AudioRealtimeChecked { get }
  /// Fills `out` with `out.count / channels` frames, interleaved.
  mutating func render(into out: UnsafeMutableBufferPointer<Float>, time: AudioTime)
}

/// Marks a type as an `AudioRenderer` and has the compiler check its
/// `render` for allocation and locks.
@attached(memberAttribute)
@attached(extension, conformances: AudioRenderer, names: named(_realtimeChecked))
public macro AudioRenderer() = #externalMacro(module: "TodhchaiMacros", type: "AudioRendererMacro")

public enum AudioError: Error, Equatable {
  /// No audio server, or it refused the stream (why).
  case unavailable(String)
  case system(Int32)
}

/// Counters a stream keeps; read from any thread.
final class AudioCounters: @unchecked Sendable {
  let underruns = Atomic<Int>(0)
  let cycles = Atomic<Int>(0)
  let running = Atomic<Bool>(true)
  /// The frames the latest render call wrote: the graph may change it.
  let period = Atomic<Int>(0)
}

/// A playing stream. It stops when stopped or dropped.
public final class AudioStream: @unchecked Sendable {
  let opened: AudioContract
  let counters: AudioCounters

  /// What the stream has now. A server can change the period while it plays
  /// (PipeWire picks one quantum for the whole graph), so this reports the
  /// latest render call's.
  public var contract: AudioContract {
    var c = opened
    let period = counters.period.load(ordering: .relaxed)
    if period > 0 && period != c.period {
      c.latency = c.latency * Double(period) / Double(c.period)
      c.period = period
    }
    return c
  }
  var thread: Thread?

  /// Render periods that came too late to be heard on time.
  public var underruns: Int { counters.underruns.load(ordering: .relaxed) }
  /// Render calls so far.
  public var cycles: Int { counters.cycles.load(ordering: .relaxed) }

  init(contract: AudioContract, counters: AudioCounters, thread: consuming Thread) {
    self.opened = contract
    self.counters = counters
    self.thread = consume thread
  }

  /// Opens a stream that plays `renderer`. With no audio server (or with
  /// `device: .clock`), it renders on a clock and plays nowhere, which
  /// tests and headless runs use.
  public static func open<R: AudioRenderer>(
    _ format: AudioFormat, periodFrames: Int, renderer: R, device: AudioDevice = .default
  ) throws(AudioError) -> AudioStream {
    switch device {
    case .clock:
      return try ClockBackend.start(format, periodFrames: periodFrames, renderer: renderer)
    case .default:
      // The desktop's PipeWire; with none, a clock (the contract says which).
      if let stream = try? PipeWireBackend.start(format, periodFrames: periodFrames, renderer: renderer) {
        return stream
      }
      return try ClockBackend.start(format, periodFrames: periodFrames, renderer: renderer)
    }
  }

  public func stop() {
    counters.running.store(false, ordering: .releasing)
    thread.take()?.join()
  }

  deinit { stop() }
}

extension Optional where Wrapped: ~Copyable {
  /// Takes the value out, leaving nil.
  mutating func take() -> Wrapped? {
    switch consume self {
    case .some(let v):
      self = nil
      return v
    case .none:
      self = nil
      return nil
    }
  }
}

/// Where a stream plays.
public enum AudioDevice: Sendable {
  /// The system's default output.
  case `default`
  /// Nowhere: rendered on a clock, at the stream's rate (tests, headless).
  case clock
}

/// A renderer handed to the audio thread, which alone uses it after.
final class RendererBox<R: AudioRenderer>: @unchecked Sendable {
  var value: R
  init(_ value: R) { self.value = value }
}

/// Plays through PipeWire, spoken directly (lib/pipewire): the graph wakes
/// the audio thread each quantum, and it renders straight into the node's
/// buffers.
enum PipeWireBackend {
  static func start<R: AudioRenderer>(_ format: AudioFormat, periodFrames: Int, renderer: R) throws(AudioError)
    -> AudioStream
  {
    let playback: PipeWirePlayback
    do {
      playback = try PipeWirePlayback(PlaybackOptions(name: "todhchai", channels: format.channels, rate: format.rate,
                                                      quantum: periodFrames))
    } catch {
      throw .unavailable("PipeWire: \(error)")
    }
    let counters = AudioCounters()
    let quantum = playback.quantum
    let period = Duration.nanoseconds(Int64(quantum) * 1_000_000_000 / Int64(format.rate))
    // Our quantum, then the sink's (a quantum is the usual estimate).
    let contract = AudioContract(format: format, period: quantum, latency: period * 2, device: "pipewire")
    let state = RendererBox(renderer)
    let node = PlaybackBox(playback)
    let thread: Thread
    do {
      thread = try Thread.spawn(
        intent: .realtime(period: period, budget: period / 2, deadline: period), name: "audio-pipewire"
      ) {
        let p = node.playback
        var fds = [pollfd(fd: p.socketFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: p.readFD, events: Int16(POLLIN), revents: 0)]
        var position: UInt64 = 0
        var lastUnderruns = 0
        while counters.running.load(ordering: .acquiring) {
          guard poll(&fds, 2, 100) > 0 else { continue }
          if fds[0].revents != 0 {
            guard (try? p.handleSocket()) != nil else { break }  // the server went away
          }
          if fds[1].revents != 0 {
            let before = p.cycles
            p.cycle { out in
              state.value.render(into: out, time: AudioTime(position: position, playsAt: Deadline.now + period * 2))
            }
            if p.cycles > before {
              position += UInt64(p.quantum)
              counters.cycles.add(1, ordering: .relaxed)
              counters.period.store(p.quantum, ordering: .relaxed)
            }
            if p.underruns > lastUnderruns {
              counters.underruns.add(p.underruns - lastUnderruns, ordering: .relaxed)
              lastUnderruns = p.underruns
            }
          }
        }
      }
    } catch {
      throw .system(0)
    }
    return AudioStream(contract: contract, counters: counters, thread: thread)
  }
}

/// The playback node, handed to the audio thread, which alone uses it after.
final class PlaybackBox: @unchecked Sendable {
  let playback: PipeWirePlayback
  init(_ playback: PipeWirePlayback) { self.playback = playback }
}

/// Renders on a clock and plays nowhere: the renderer runs every period on
/// a real-time thread, and a period that starts after its deadline counts
/// as an underrun.
enum ClockBackend {
  static func start<R: AudioRenderer>(_ format: AudioFormat, periodFrames: Int, renderer: R) throws(AudioError)
    -> AudioStream
  {
    let counters = AudioCounters()
    let period = Duration.nanoseconds(Int64(periodFrames) * 1_000_000_000 / Int64(format.rate))
    let contract = AudioContract(format: format, period: periodFrames, latency: period, device: "clock")
    let state = RendererBox(renderer)
    let thread: Thread
    do {
      thread = try Thread.spawn(
        intent: .realtime(period: period, budget: period / 2, deadline: period), name: "audio-clock"
      ) {
        let samples = periodFrames * format.channels
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: samples)
        defer { buffer.deallocate() }
        var position: UInt64 = 0
        var deadline = Deadline.now + period
        while counters.running.load(ordering: .acquiring) {
          sleep(until: deadline)
          let late = Deadline.now.since(deadline)
          if late > period { counters.underruns.add(1, ordering: .relaxed) }
          buffer.update(repeating: 0)
          state.value.render(into: buffer, time: AudioTime(position: position, playsAt: deadline + period))
          position += UInt64(periodFrames)
          counters.cycles.add(1, ordering: .relaxed)
          deadline = deadline + period
          if Deadline.now > deadline + period {
            // Far behind (the machine was stalled): skip ahead rather than
            // render a burst.
            deadline = Deadline.now + period
          }
        }
      }
    } catch {
      throw .system(0)
    }
    return AudioStream(contract: contract, counters: counters, thread: thread)
  }
}
