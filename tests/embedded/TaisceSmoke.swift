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
    } catch {
      check(false, "a Taisce call threw")
    }
    print("embedded Taisce: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
