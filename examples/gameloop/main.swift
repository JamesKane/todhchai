// SPDX-License-Identifier: BSD-3-Clause

// game loop: 64 sprites bouncing, simulated on the CPU at the display's
// rate and drawn with Loinnir (sdk.md §5), one instanced draw a frame.
// The budget is frame error: when each frame reached the glass against
// when its frame event said it would (p99 ≤ 1 ms, docs/performance.md).
//
//   swift build --product gameloop && .build/debug/gameloop     (escape quits)
//
// Run from the repository root (it loads examples/gameloop/shaders/*.spv).
// TODHCHAI_GAMELOOP_FRAMES=N stops after N frames; the trace mark "steady"
// comes after the first 120, once the timing is measured.

import Glibc
import Loinnir
import Todhchai
import Trace

struct Sprite {
  var x: Float, y: Float, w: Float, h: Float
  var r: Float, g: Float, b: Float, a: Float
  var vx: Float, vy: Float  // velocity, clip space a second (not uploaded)
}

func spirv(_ path: String) -> [UInt8] {
  guard let f = fopen(path, "rb") else { return [] }
  defer { fclose(f) }
  var bytes: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { bytes += chunk[..<n] }
  return bytes
}

let frameLimit = getenv("TODHCHAI_GAMELOOP_FRAMES").flatMap { Int(String(cString: $0)) }

var loop = try Loop()
let win = try loop.openWindow("game loop", width: 960, height: 540)
let gpu = try Loinnir.open(window: win, loop: &loop)
let pso = try gpu.pipeline(vertex: spirv("examples/gameloop/shaders/sprite.vert.spv"),
                           fragment: spirv("examples/gameloop/shaders/sprite.frag.spv"), target: .bgra8)

// The world: deterministic, so every run draws the same thing.
struct Random {
  var seed: UInt32 = 12345
  mutating func next() -> Float {
    seed = seed &* 1_664_525 &+ 1_013_904_223
    return Float(seed >> 8) / Float(1 << 24)
  }
}
var rng = Random()
var sprites: [Sprite] = []
for _ in 0..<64 {
  sprites.append(Sprite(x: rng.next() * 1.6 - 0.8, y: rng.next() * 1.6 - 0.8, w: 0.03 + rng.next() * 0.05,
                        h: 0.03 + rng.next() * 0.05, r: rng.next(), g: rng.next(), b: rng.next(), a: 0.9,
                        vx: rng.next() * 1.2 - 0.6, vy: rng.next() * 1.2 - 0.6))
}
let upload = try gpu.alloc(.upload, bytes: sprites.count * 32)  // vec2, vec2, vec4 per sprite (std430)
let instances = upload.pointer!.assumingMemoryBound(to: Float.self)

var config: Configure?
var last: Deadline?
var frames = 0
loop.requestFrame(win)

main: while true {
  for e in loop.wait() {
    switch e.payload {
    case .configure(let c): config = c
    case .frame(let f):
      // Simulate up to when this frame will be seen, not when it was asked for.
      let dt = last.map { Float(f.target.since($0).nanoseconds) * 1e-9 } ?? 0
      last = f.target
      for i in sprites.indices {
        sprites[i].x += sprites[i].vx * dt
        sprites[i].y += sprites[i].vy * dt
        if abs(sprites[i].x) > 1 - sprites[i].w { sprites[i].vx = -sprites[i].vx }
        if abs(sprites[i].y) > 1 - sprites[i].h { sprites[i].vy = -sprites[i].vy }
        let s = sprites[i]
        (instances[i * 8], instances[i * 8 + 1], instances[i * 8 + 2], instances[i * 8 + 3]) = (s.x, s.y, s.w, s.h)
        (instances[i * 8 + 4], instances[i * 8 + 5], instances[i * 8 + 6], instances[i * 8 + 7]) = (s.r, s.g, s.b, s.a)
      }
      if let c = config, let target = try gpu.frame(&loop, c) {
        var cmd = try gpu.commands()
        cmd.render(to: target, clear: (0.05, 0.05, 0.08, 1)) { r in
          r.draw(pso, root: upload.address, vertices: 6, instances: UInt32(sprites.count))
        }
        try gpu.present(&loop, c, after: try gpu.submit(cmd))
        frames += 1
        if frames == 120 { Trace.mark("steady") }
        if frames == frameLimit { break main }
      }
      loop.requestFrame(win)
    case .keyDown(let k) where k.usage == .escape: break main
    case .close, .quit: break main
    default: break
    }
  }
}
Trace.mark("steady.end")
loop.closeWindow(win)
