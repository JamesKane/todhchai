// SPDX-License-Identifier: BSD-3-Clause

import Elf
import Foundation
import Testing

/// A little ELF64 executable: a header, then program headers.
func elf(type: UInt16 = 2, machine: UInt16 = ElfImage.Machine.amd64, entry: UInt64 = 0x101_0000,
         phoff: UInt64 = 64, headers: [(type: UInt32, flags: UInt32, offset: UInt64, vaddr: UInt64, filesz: UInt64,
                                       memsz: UInt64)], size: Int = 0x3000) -> [UInt8]
{
  var b = [UInt8](repeating: 0, count: max(size, Int(phoff) + 56 * headers.count))
  func put(_ v: UInt64, _ at: Int, _ n: Int) { for i in 0..<n { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
  b[0] = 0x7F
  b[1] = UInt8(ascii: "E")
  b[2] = UInt8(ascii: "L")
  b[3] = UInt8(ascii: "F")
  b[4] = 2
  b[5] = 1
  b[6] = 1
  put(UInt64(type), 16, 2)
  put(UInt64(machine), 18, 2)
  put(1, 20, 4)
  put(entry, 24, 8)
  put(phoff, 32, 8)
  put(64, 52, 2)
  put(56, 54, 2)
  put(UInt64(headers.count), 56, 2)
  for (i, h) in headers.enumerated() {
    let at = Int(phoff) + 56 * i
    put(UInt64(h.type), at, 4)
    put(UInt64(h.flags), at + 4, 4)
    put(h.offset, at + 8, 8)
    put(h.vaddr, at + 16, 8)
    put(h.filesz, at + 32, 8)
    put(h.memsz, at + 40, 8)
    put(4096, at + 48, 8)
  }
  return b
}

let text: (type: UInt32, flags: UInt32, offset: UInt64, vaddr: UInt64, filesz: UInt64, memsz: UInt64) =
  (1, 5, 0x1000, 0x101_0000, 0x800, 0x800)
let data: (type: UInt32, flags: UInt32, offset: UInt64, vaddr: UInt64, filesz: UInt64, memsz: UInt64) =
  (1, 6, 0x2000, 0x102_0000, 0x10, 0x5000)
let stack: (type: UInt32, flags: UInt32, offset: UInt64, vaddr: UInt64, filesz: UInt64, memsz: UInt64) =
  (0x6474_E551, 6, 0, 0, 0, 0x8_0000)

@Test func readsAnExecutable() throws {
  let image = try ElfImage(header: elf(headers: [text, data, stack]), fileSize: 0x3000, machine: ElfImage.Machine.amd64)
  #expect(image.kind == .executable)
  #expect(image.entry == 0x101_0000)
  #expect(image.segments.count == 2)
  #expect(image.segments[0].executable && image.segments[0].readable && !image.segments[0].writable)
  #expect(image.segments[1].writable && image.segments[1].memsz == 0x5000)
  #expect(image.stackSize == 0x8_0000)
}

@Test func asksForMoreWhenProgramHeadersAreFarther() throws {
  let file = elf(phoff: 0x2000, headers: [text], size: 0x3000)
  #expect(throws: ElfImage.Error.needs(0x2000 + 56)) { try ElfImage(header: Array(file[0..<4096]), fileSize: file.count) }
  #expect(try ElfImage(header: file, fileSize: file.count).segments.count == 1)
}

@Test func refusesWhatItCantLoad() throws {
  #expect(throws: ElfImage.Error.notElf) { try ElfImage(header: [UInt8](repeating: 0, count: 64), fileSize: 64) }
  #expect(throws: ElfImage.Error.notElf) { try ElfImage(header: elf(type: 1, headers: []), fileSize: 0x3000) }
  #expect(throws: ElfImage.Error.wrongMachine(ElfImage.Machine.arm64)) {
    try ElfImage(header: elf(machine: ElfImage.Machine.arm64, headers: []), fileSize: 0x3000,
                 machine: ElfImage.Machine.amd64)
  }
  // Past the file's end; larger in the file than in memory; not congruent.
  for bad in [(UInt32(1), UInt32(4), UInt64(0x2000), UInt64(0x10_0000), UInt64(0x2000), UInt64(0x2000)),
              (1, 4, 0x1000, 0x10_0000, 0x100, 0x80), (1, 4, 0x1000, 0x10_0010, 0x100, 0x100)]
  {
    #expect(throws: ElfImage.Error.badSegment(0)) { try ElfImage(header: elf(headers: [bad]), fileSize: 0x3000) }
  }
  #expect(try ElfImage(header: elf(type: 3, headers: []), fileSize: 0x3000).kind == .shared)
}

/// The native build's programs, if it has been built: what the loader meets.
@Test func readsTheNativePrograms() throws {
  let path = "build/native-amd64/bin/sys-test"
  guard let data = FileManager.default.contents(atPath: path) else { return }
  let image = try ElfImage(header: Array(data.prefix(4096)), fileSize: data.count, machine: ElfImage.Machine.amd64)
  #expect(image.kind == .executable)
  #expect(image.segments.contains { $0.executable } && image.segments.contains { $0.writable })
  #expect(image.segments.allSatisfy { $0.offset % 4096 == 0 && $0.vaddr % 4096 == 0 })
  #expect(image.stackSize == 262_144)
}
