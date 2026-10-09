// SPDX-License-Identifier: BSD-3-Clause

// Sounds (sdk.md §7): WAV files decoded once to interleaved Float at the
// mixer's rate. Written from Microsoft's RIFF/WAVE description
// (WAVEFORMATEX and WAVEFORMATEXTENSIBLE): PCM 8, 16, 24 and 32-bit, and
// IEEE float 32 and 64-bit.

import FoundationEssentials

public enum SoundError: Error, Equatable {
  case unreadable(String)
  /// Not RIFF/WAVE, or a format this loader doesn't decode (why).
  case unsupported(String)
}

/// Decoded audio. Its samples live as long as the process, so a voice on
/// the real-time thread can read them without counting references.
public struct Sound: @unchecked Sendable {  // its samples are immutable once made
  public let channels: Int
  public let rate: Int
  public let frames: Int
  let samples: UnsafePointer<Float>  // channels × frames, interleaved; never freed

  /// Loads a WAV file, resampled to `rate` (linear interpolation).
  public static func load(_ path: String, rate: Int = 48_000) throws(SoundError) -> Sound {
    guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable(path) }
    return try decode([UInt8](data), rate: rate)
  }

  /// Decodes WAV bytes.
  public static func decode(_ b: [UInt8], rate: Int = 48_000) throws(SoundError) -> Sound {
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    guard b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WAVE".utf8) else {
      throw .unsupported("not a RIFF/WAVE file")
    }
    var format = -1, channels = 0, fileRate = 0, bits = 0
    var data: Range<Int>?
    var at = 12
    while at + 8 <= b.count {
      let id = b[at..<(at + 4)], size = u32(at + 4), body = at + 8
      guard body + size <= b.count else {
        if id.elementsEqual("data".utf8) { data = body..<b.count }  // truncated data chunk: take what's there
        break
      }
      if id.elementsEqual("fmt ".utf8), size >= 16 {
        format = u16(body)
        channels = u16(body + 2)
        fileRate = u32(body + 4)
        bits = u16(body + 14)
        if format == 0xfffe, size >= 40 { format = u16(body + 24) }  // the extensible format's subformat
      } else if id.elementsEqual("data".utf8) {
        data = body..<(body + size)
      }
      at = body + size + (size & 1)  // chunks are padded to even sizes
    }
    guard let data, channels > 0, fileRate > 0 else { throw .unsupported("no fmt or data chunk") }
    let bytesPerSample = bits / 8
    guard (format == 1 && [8, 16, 24, 32].contains(bits)) || (format == 3 && [32, 64].contains(bits)) else {
      throw .unsupported("format \(format), \(bits) bits")
    }
    let frameCount = data.count / (bytesPerSample * channels)
    var decoded = [Float](repeating: 0, count: frameCount * channels)
    for i in 0..<(frameCount * channels) {
      let o = data.lowerBound + i * bytesPerSample
      switch (format, bits) {
      case (1, 8): decoded[i] = (Float(b[o]) - 128) / 128
      case (1, 16): decoded[i] = Float(Int16(truncatingIfNeeded: u16(o))) / 32768
      case (1, 24): decoded[i] = Float(Int32(truncatingIfNeeded: u32(o - 1) & ~0xff) >> 8) / 8_388_608
      case (1, 32): decoded[i] = Float(Int32(truncatingIfNeeded: u32(o))) / 2_147_483_648
      case (3, 32): decoded[i] = Float(bitPattern: UInt32(u32(o)))
      default: decoded[i] = Float(Double(bitPattern: UInt64(u32(o)) | UInt64(u32(o + 4)) << 32))
      }
    }
    return make(resample(decoded, channels: channels, from: fileRate, to: rate), channels: channels, rate: rate)
  }

  /// A sound from samples already at `rate` (interleaved).
  public static func make(_ samples: [Float], channels: Int, rate: Int) -> Sound {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
    p.initialize(from: samples, count: samples.count)
    return Sound(channels: channels, rate: rate, frames: samples.count / channels, samples: p)
  }

  static func resample(_ s: [Float], channels: Int, from: Int, to: Int) -> [Float] {
    guard from != to, !s.isEmpty else { return s }
    let inFrames = s.count / channels
    let outFrames = Int((Int64(inFrames) * Int64(to) + Int64(from) - 1) / Int64(from))
    var out = [Float](repeating: 0, count: outFrames * channels)
    let step = Double(from) / Double(to)
    for f in 0..<outFrames {
      let x = Double(f) * step
      let i = min(Int(x), inFrames - 1), j = min(i + 1, inFrames - 1)
      let t = Float(x - Double(i))
      for c in 0..<channels { out[f * channels + c] = s[i * channels + c] * (1 - t) + s[j * channels + c] * t }
    }
    return out
  }
}
