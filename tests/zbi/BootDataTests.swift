// SPDX-License-Identifier: BSD-3-Clause

// croi's boot data (K9b) read back from containers built here as croi's
// zbi.h lays them out.

import Testing
import ZBI

func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

func header(_ type: UInt32, _ length: Int, extra: UInt32 = 0, flags: UInt32 = BootData.flagsVersion,
            magic: UInt32 = BootData.itemMagic) -> [UInt8]
{
  le(UInt64(type), 4) + le(UInt64(length), 4) + le(UInt64(extra), 4) + le(UInt64(flags), 4) + le(0, 8)
    + le(UInt64(magic), 4) + le(0x4A87_E8D6, 4)
}

func item(_ type: UInt32, _ payload: [UInt8]) -> [UInt8] {
  let padded = payload + [UInt8](repeating: 0, count: (8 - payload.count % 8) % 8)
  return header(type, payload.count) + padded
}

func container(_ items: [[UInt8]]) -> [UInt8] {
  let body = items.flatMap { $0 }
  return header(BootData.ItemType.container, body.count, extra: BootData.containerMagic) + body
}

@Test func readsCroisItems() throws {
  let fb = le(0x8000_0000, 8) + le(1280, 4) + le(800, 4) + le(1280, 4) + le(UInt64(BootData.Framebuffer.rgbx888), 4)
  let memory = le(0x10_0000, 8) + le(0x7F00_0000, 8) + le(1, 4) + le(0, 4)
    + le(0x7FF0_0000, 8) + le(0x2_0000, 8) + le(3, 4) + le(0, 4)
  let unknown = item(0x5858_5858, [1, 2, 3])  // skipped, padding and all
  var bytes = container([item(BootData.ItemType.acpiRSDP, le(0x7FFB_1014, 8)), unknown,
                         item(BootData.ItemType.smbios, le(0x7FF0_0000, 8)), item(BootData.ItemType.framebuffer, fb),
                         item(BootData.ItemType.memConfig, memory)])
  bytes += [UInt8](repeating: 0, count: 4096 - bytes.count)  // the VMO is a page
  let data = try BootData(bytes)
  #expect(data.rsdp == 0x7FFB_1014)
  #expect(data.smbios == 0x7FF0_0000)
  #expect(data.framebuffer == BootData.Framebuffer(base: 0x8000_0000, width: 1280, height: 800, stride: 1280,
                                                   format: BootData.Framebuffer.rgbx888))
  #expect(data.framebuffer?.size == 1280 * 800 * 4)
  #expect(data.memory.map { $0.kind } == [.ram, .reserved])
  #expect(data.range(holding: 0x7FF1_0000)?.kind == .reserved)
  #expect(data.range(holding: 0x9000_0000) == nil)
}

@Test func refusesMalformedContainers() {
  #expect(throws: BootData.Failure.truncated) { try BootData([1, 2, 3]) }
  #expect(throws: BootData.Failure.notAContainer) {
    try BootData(header(BootData.ItemType.container, 0, extra: 0))
  }
  var bad = container([item(BootData.ItemType.acpiRSDP, le(1, 8))])
  bad[32 + 24] = 0  // the item's magic
  #expect(throws: BootData.Failure.badItem(32)) { try BootData(bad) }
  let short = container([item(BootData.ItemType.acpiRSDP, le(1, 4))])
  #expect(throws: BootData.Failure.badItem(32)) { try BootData(short) }
  #expect(throws: BootData.Failure.truncated) { try BootData(Array(container([item(BootData.ItemType.acpiRSDP, le(1, 8))]).prefix(40))) }
}
