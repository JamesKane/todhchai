// SPDX-License-Identifier: BSD-3-Clause

// bin/console (M3j): the framebuffer text console. It maps the GOP
// framebuffer that croi's boot data names (`bootdata`; a physical VMO
// under its `resource mmio`, write-combining) and shows the system's log
// as it comes: it reads croi's debuglog (`resource system` grants the
// debuglog resource) from the oldest record kept, each record a line as
// croi's console prints it, warnings amber and errors magenta. Text
// written to its `write` leaf is shown too.
//
// Its tree:
//   status   the framebuffer, the grid, when the first frame was drawn
//            (monotonic time, which starts at kernel entry), records shown
//   screen   the grid's text, a line a row
//   write    text written here is shown (ink)

import Console
import IPC
import Launch
import LibSys
import Node
import Sys
import ZBI

@main struct ConsoleProgram {
  static func fail(_ what: String) -> Never {
    print("console: \(what)")
    exit(1)
  }

  /// A record as croi's console prints it: `[sssss.mmm] pid:tid> text`.
  static func line(_ r: Debuglog.Record) -> [UInt8] {
    func digits(_ v: UInt64, _ width: Int) -> String {
      var s = String(v)
      while s.utf8.count < width { s = "0" + s }
      return s
    }
    let ms = UInt64(max(r.timestamp, 0)) / 1_000_000
    let head = "[\(digits(ms / 1000, 5)).\(digits(ms % 1000, 3))] \(digits(r.pid, 5)):\(digits(r.tid, 5))> "
    var text = r.text
    while text.last == 0x0A { text.removeLast() }
    return Array(head.utf8) + text + [0x0A]
  }

  /// The color of a record's line by its severity.
  static func color(_ severity: UInt8) -> UInt8 {
    switch severity {
    case 0x60...: 4  // fatal, error: magenta
    case 0x50...: 4
    case 0x40...: 3  // warning: amber
    default: 0  // phosphor
    }
  }

  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { fail("no Startup handle") }
    var start: Startup
    do { start = try Startup(Handle(raw: raw)) } catch { fail("can't read Startup") }
    guard let mmioRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (manifest: resource mmio)")
    }
    let mmio = Handle(raw: mmioRaw)

    // The framebuffer, from the boot data.
    guard let dataRaw = StartupHandles.take(ProcessArgs.info(HandleType.vmoBootData)) else {
      fail("no boot data (manifest: bootdata)")
    }
    let dataVMO = Handle(raw: dataRaw)
    guard let header = try? VMO.read(dataVMO, offset: 0, count: BootData.headerSize),
      let length = try? BootData.length(header: header), let bytes = try? VMO.read(dataVMO, offset: 0, count: length),
      let data = try? BootData(bytes)
    else { fail("the boot data is malformed") }
    guard let fb = data.framebuffer, let format = PixelFormat(zbi: fb.format) else {
      fail("no linear framebuffer in the boot data")
    }
    let t0 = Clock.monotonic()
    let pageBase = fb.base & ~4095
    let size = Int((fb.base - pageBase + fb.size + 4095) & ~4095)
    let mapping: Mapping
    do throws(Status) {
      let resource = try Sys.Resource.create(parent: mmio, kind: .mmio, base: pageBase, size: UInt64(size), name: "framebuffer")
      let vmo = try VMO.physical(resource: resource, address: pageBase, size: size)
      try VMO.setCachePolicy(vmo, .writeCombining)
      mapping = try VMO.map(vmo, length: size)
    } catch {
      fail("can't map the framebuffer: \(error)")
    }
    let font = fb.width >= 2560 ? Font.spleen16x32 : Font.spleen8x16
    let renderer = unsafe Renderer(unsafe: mapping.address + Int(fb.base - pageBase), width: Int(fb.width),
                                   height: Int(fb.height), stride: Int(fb.stride), format: format, font: font)

    // The grid, shared by the log's thread and the tree's.
    final class Shared: @unchecked Sendable {
      let lock = Lock()
      var grid: TextGrid
      var records = 0
      var dropped: UInt64 = 0
      var frames = 0
      var drawNanoseconds: Int64 = 0
      init(_ grid: TextGrid) { self.grid = grid }
    }
    let shared = Shared(renderer.grid())
    func show(_ color: UInt8, _ bytes: [UInt8]) {
      shared.grid.color = color
      shared.grid.write(bytes)
    }
    func draw() {
      let t = Clock.monotonic()
      renderer.render(&shared.grid)
      shared.frames += 1
      shared.drawNanoseconds += Clock.monotonic() - t
    }
    let title = "Todhchai console: \(fb.width)x\(fb.height), \(shared.grid.columns)x\(shared.grid.rows) cells of Spleen \(font.width)x\(font.height)\n"
    shared.lock.withLock {
      show(2, Array(title.utf8))
      draw()
    }
    let firstFrame = Clock.monotonic()
    print("console: first frame at \(firstFrame / 1_000_000) ms (mapping and drawing \((firstFrame - t0) / 1000) us)")

    // The log, on a thread of its own.
    if let systemRaw = StartupHandles.take(ProcessArgs.info(HandleType.resource(.system))) {
      let system = Handle(raw: systemRaw)
      do throws(Status) {
        let resource = try Sys.Resource.create(parent: system, kind: .system, base: Debuglog.systemBase, size: 1,
                                               name: "console")
        let log = try Debuglog.reader(resource: resource)
        let logRaw = log.release()
        _ = try Thread.spawn {
          let log = Handle(raw: logRaw)
          var last: UInt64 = 0
          while true {
            var batch: [Debuglog.Record] = []
            while let r = try? Debuglog.read(log) { batch.append(r) }
            if !batch.isEmpty {
              shared.lock.withLock {
                for r in batch {
                  if last != 0 && r.sequence > last + 1 { shared.dropped += r.sequence - last - 1 }
                  last = r.sequence
                  show(color(r.severity), line(r))
                }
                shared.records += batch.count
                draw()
              }
            }
            _ = try? log.wait(for: Signals.readable)
          }
        }
      } catch {
        print("console: can't read the log: \(error)")
      }
    } else {
      print("console: no system resource (manifest: resource system): the log isn't shown")
    }

    let dispatcher: IPCDispatcher
    do { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let geometry = "framebuffer \(fb.width)x\(fb.height) stride \(fb.stride) \(format == .rgbx888 ? "rgbx888" : "bgr888x")\n"
      + "font spleen \(font.width)x\(font.height)\nfirst frame \(firstFrame) ns\n"
    tree.text("status", read: {
      shared.lock.withLock {
        geometry + "grid \(shared.grid.columns)x\(shared.grid.rows)\nrecords \(shared.records) dropped \(shared.dropped)\n"
          + "frames \(shared.frames) drawing \(shared.drawNanoseconds / 1000) us\n"
      }
    })
    tree.text("screen", read: {
      shared.lock.withLock { (0..<shared.grid.rows).map { shared.grid.text($0) + "\n" }.joined() }
    })
    tree.text("write", read: { "" }, write: { text throws(NodeError) in
      shared.lock.withLock {
        show(1, Array(text.utf8))
        draw()
      }
    })
    do {
      try tree.serve(try start.export())
      try start.ready()
    } catch {
      fail("can't serve")
    }
    _ = try? dispatcher.run()
    _ = consume mapping
  }
}
