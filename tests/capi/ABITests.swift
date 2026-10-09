// SPDX-License-Identifier: BSD-3-Clause

// libtodhchai's C ABI: the generated files are current, the layouts abigen
// computes are the ones C (through Swift's importer) gives, and the
// functions behave as sdk.md §12 says, without a window. The calls go
// through the C declarations; TodhchaiCABI is linked, not imported.

import ABIGen
import Glibc
import TDCABI
import Testing
import Todhchai

let root: String = {
  var dir = #filePath
  for _ in 0..<3 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }
  return dir
}()

func read(_ path: String) -> String {
  guard let f = fopen("\(root)/\(path)", "rb") else { return "" }
  defer { fclose(f) }
  var bytes: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65536)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { bytes += chunk[..<n] }
  return String(decoding: bytes, as: UTF8.self)
}

let abi = todhchaiABI(keys: keyUsages(in: read("lib/sdk/KeyUsage.swift")))

@Suite struct Generated {
  @Test func theCommittedOutputsAreCurrent() {
    // Regenerate: .build/debug/abigen lib/sdk/KeyUsage.swift lib/capi/c/include/todhchai/todhchai.h
    //   lib/capi/zig/todhchai.zig lib/capi/odin/todhchai/todhchai.odin
    #expect(read("lib/capi/c/include/todhchai/todhchai.h") == emitC(abi))
    #expect(read("lib/capi/zig/todhchai.zig") == emitZig(abi))
    #expect(read("lib/capi/odin/todhchai/todhchai.odin") == emitOdin(abi))
  }

  @Test func everyKeyUsageIsAConstant() {
    let keys = keyUsages(in: read("lib/sdk/KeyUsage.swift"))
    #expect(keys.count >= 100)
    #expect(keys.first { $0.name == "space" }?.usage == KeyUsage.space.rawValue)
    #expect(UInt16(TD_KEY_SPACE) == KeyUsage.space.rawValue)
    #expect(UInt16(TD_KEY_ESCAPE) == KeyUsage.escape.rawValue)
    #expect(UInt16(TD_KEY_NON_US_HASH) == KeyUsage.nonUSHash.rawValue)
    #expect(UInt16(TD_KEY_F12) == KeyUsage.f12.rawValue)
  }

  @Test func namesBecomeUpperSnakeCase() {
    #expect(upperSnake("leftBracket") == "LEFT_BRACKET")
    #expect(upperSnake("nonUSHash") == "NON_US_HASH")
    #expect(upperSnake("digit1") == "DIGIT1")
    #expect(upperSnake("f1") == "F1")
  }

  @Test func layoutsAreCs() {
    let swift: [String: (size: Int, align: Int)] = [
      "td_window": (MemoryLayout<td_window>.size, MemoryLayout<td_window>.alignment),
      "td_sound": (MemoryLayout<td_sound>.size, MemoryLayout<td_sound>.alignment),
      "td_configure_event": (MemoryLayout<td_configure_event>.size, MemoryLayout<td_configure_event>.alignment),
      "td_frame_event": (MemoryLayout<td_frame_event>.size, MemoryLayout<td_frame_event>.alignment),
      "td_key_event": (MemoryLayout<td_key_event>.size, MemoryLayout<td_key_event>.alignment),
      "td_pointer_event": (MemoryLayout<td_pointer_event>.size, MemoryLayout<td_pointer_event>.alignment),
      "td_wheel_event": (MemoryLayout<td_wheel_event>.size, MemoryLayout<td_wheel_event>.alignment),
      "td_timer_event": (MemoryLayout<td_timer_event>.size, MemoryLayout<td_timer_event>.alignment),
      "td_message_event": (MemoryLayout<td_message_event>.size, MemoryLayout<td_message_event>.alignment),
      "td_event": (MemoryLayout<td_event>.size, MemoryLayout<td_event>.alignment),
      "td_events": (MemoryLayout<td_events>.size, MemoryLayout<td_events>.alignment),
      "td_window_desc": (MemoryLayout<td_window_desc>.size, MemoryLayout<td_window_desc>.alignment),
      "td_cpu_surface": (MemoryLayout<td_cpu_surface>.size, MemoryLayout<td_cpu_surface>.alignment),
    ]
    for r in abi.records where !r.anonymousInC {
      let ours = abi.recordLayout(r)
      #expect(swift[r.name] != nil, "\(r.name) isn't checked here")
      if let s = swift[r.name] { #expect(s == ours, "\(r.name)") }
    }
    #expect(MemoryLayout<td_event>.size == 80)  // sdk.md §2
    #expect(MemoryLayout<td_event>.offset(of: \.seq) == 24)
  }
}

@Suite struct Exports {
  @Test func everyDeclaredFunctionIsExported() {
    let functions = abi.decls.compactMap { if case .function(let f) = $0 { f.name } else { nil } }
    #expect(functions.count >= 20)
    for name in functions {
      #expect(dlsym(UnsafeMutableRawPointer(bitPattern: 0), name) != nil, "\(name) isn't exported")
    }
  }
}

@Suite struct Behavior {
  @Test func aTimerArrivesAsAnEvent() throws {
    let loop = try #require(td_loop_create())
    defer { td_loop_destroy(loop) }
    let timer = td_timer_set(loop, td_now() + 1_000_000, 0, 0)
    #expect(timer != 0)
    var got: td_event?
    let giveUp = td_now() + 2_000_000_000
    while got == nil && td_now() < giveUp {
      let ev = td_loop_wait(loop, giveUp, 0)
      for i in 0..<ev.count where ev.items[i].kind == UInt16(TD_EV_TIMER) { got = ev.items[i] }
    }
    let e = try #require(got)
    #expect(e.timer.timer == timer)
    #expect(e.seq >= 1)
    #expect(e.window.index == 0)
  }

  @Test func aPostedMessageArrives() throws {
    let loop = try #require(td_loop_create())
    defer { td_loop_destroy(loop) }
    td_loop_post(loop, 7, 9)
    let ev = td_loop_wait(loop, td_now() + 1_000_000_000, 0)
    #expect(ev.count == 1)
    #expect(ev.items[0].kind == UInt16(TD_EV_MESSAGE))
    #expect(ev.items[0].message.a == 7 && ev.items[0].message.b == 9)
  }

  @Test func misuseIsReportedNotFatal() throws {
    #expect(td_loop_wait(nil, 0, 0).count == 0)
    #expect(String(cString: td_last_error()!).contains("NULL"))
    let loop = try #require(td_loop_create())
    defer { td_loop_destroy(loop) }
    // A stale or made-up window is ignored.
    td_window_close(loop, td_window(index: 99, generation: 3))
    td_frame_request(loop, td_window(index: 99, generation: 3))
    var s = td_cpu_surface()
    #expect(!td_cpu_surface_acquire(loop, td_window(index: 99, generation: 3), &s))
    #expect(td_present(loop, td_window(index: 99, generation: 3), nil, 1) == TD_ERR_INVALID_ARGS)
    // An input struct whose size is too small is refused.
    var desc = td_window_desc()
    desc.size = 8
    #expect(td_window_open_desc(loop, &desc).index == 0)
    #expect(String(cString: td_last_error()!).contains("size"))
  }

  @Test func soundsAreGenerationHandles() throws {
    let bad = td_sound_load("/nonexistent.wav")
    #expect(bad.index == 0)
    #expect(!String(cString: td_last_error()!).isEmpty)
    let beep = td_sound_load("\(root)/examples/minimal/beep.wav")
    #expect(beep.index != 0)
    td_sound_free(beep)
    #expect(td_mixer_play(beep, 1) == 0)  // stale: refused before any audio opens
    let again = td_sound_load("\(root)/examples/minimal/beep.wav")
    #expect(again.index == beep.index && again.generation == beep.generation + 1)
    td_sound_free(again)
  }

  @Test func errorsArePerThread() throws {
    _ = td_loop_wait(nil, 0, 0)
    let here = String(cString: td_last_error()!)
    #expect(!here.isEmpty)
    // A new thread (not a pool thread another test may have used) has none.
    final class Seen: @unchecked Sendable { var text = "unset" }
    let seen = Seen()
    let t = try Thread.spawn(intent: .throughput) { seen.text = String(cString: td_last_error()!) }
    t.join()
    #expect(seen.text.isEmpty)
    #expect(String(cString: td_last_error()!) == here)  // and this thread's is still its own
  }
}
