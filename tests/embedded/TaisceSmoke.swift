// SPDX-License-Identifier: BSD-3-Clause

// Taisce built as Embedded Swift on the host: format a volume in memory,
// commit, crash part-way, and open what's left. tests/taisce is thorough.

import Taisce

@main struct TaisceSmoke {
  static func main() {
    do {
      check(CRC32C.checksum([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]) == 0xE306_9283, "crc32c")
      let v = try Volume.format(MemoryDevice(blocks: 1024), label: [0x74], uuid: [UInt8](repeating: 7, count: 16),
                                now: 1)
      let image = v.device
      var r = try Volume.open(RecordingDevice(image))
      let extents = try r.allocator.allocate(40)
      check(extents.count == 1 && extents[0].count == 40, "allocate")
      try r.commit()
      for k in 0...r.device.log.count {
        let opened = try Volume.open(image.applying(r.device.log.prefix(k)))
        check(opened.superblock.layout == v.superblock.layout, "open after a crash")
      }
      check(try Volume.open(r.device.base).allocator.freeCount == r.allocator.freeCount, "free space persists")
      var store = Store(try Volume.format(MemoryDevice(blocks: 4096), label: [], uuid: [UInt8](repeating: 1, count: 16), now: 0))
      var tree = BTree()
      for k in 0..<2000 { try tree.insert([UInt8(k >> 8), UInt8(k & 0xff)], [UInt8](repeating: 9, count: 100), &store) }
      for k in stride(from: 0, to: 2000, by: 2) { try tree.delete([UInt8(k >> 8), UInt8(k & 0xff)], &store) }
      check(try tree.check(&store).entries == 1000, "b+tree")
      check(try tree.get([0, 1], &store) != nil && tree.get([0, 2], &store) == nil, "b+tree lookups")
      // The engine: a group committed, a crash before the next one's
      // commit point, and a remount that replays the log.
      var e = try Engine.format(MemoryDevice(blocks: 2048), label: [], uuid: [UInt8](repeating: 2, count: 16), now: 0)
      try e.apply([.insert(tree: 1, key: [1], value: [UInt8](repeating: 0, count: 8)),
                   .delta(tree: 1, key: [1], .add(offset: 0, value: 41))])
      try e.commitGroup()
      try e.apply([.insert(tree: 1, key: [2], value: [2])])  // never committed
      var m = try Engine.mount(e.store.volume.device)
      check(try m.get(1, [1]) == [41, 0, 0, 0, 0, 0, 0, 0] && m.get(1, [2]) == nil, "engine replay")
      check(try m.check().entries == 1, "engine check")
      // Files: a directory, data with a hole, a rename, and a remount.
      var fs = try FileSystem.format(MemoryDevice(blocks: 4096), label: [], uuid: [UInt8](repeating: 3, count: 16), now: 1)
      let dir = try fs.create(1, [0x64], .directory, mode: 0o755, now: 2)
      let file = try fs.create(dir, [0x66], .file, mode: 0o644, now: 3)
      try fs.write(file, offset: 9000, [1, 2, 3], now: 4)
      try fs.rename(dir, [0x66], 1, [0x67], now: 5)
      try fs.sync()
      var again = try FileSystem.mount(fs.engine.store.volume.device)
      check(try again.lookup(1, [0x67]) == file, "fs rename")
      check(try again.read(file, offset: 8999, count: 10) == [0, 1, 2, 3], "fs data")
      check(try again.check() == 3, "fs check")
    } catch {
      check(false, "a Taisce call threw")
    }
    print("embedded Taisce: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
