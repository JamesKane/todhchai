// SPDX-License-Identifier: BSD-3-Clause

import Glibc
import Testing
import Todhchai

@Test func reserveCommitDecommit() throws {
  let range = try Memory.reserve(1 << 20)
  defer { Memory.release(range) }
  #expect(range.count == 1 << 20)
  let page = UnsafeMutableRawBufferPointer(rebasing: range[0..<Memory.pageSize])
  try Memory.commit(page)
  page.storeBytes(of: 0xabcd, as: UInt32.self)
  #expect(page.load(as: UInt32.self) == 0xabcd)
  try Memory.decommit(page)
  try Memory.commit(page)
  #expect(page.load(as: UInt32.self) == 0)  // decommitted memory comes back zeroed
  #expect(throws: MemoryError.misaligned) {
    try Memory.commit(UnsafeMutableRawBufferPointer(rebasing: range[1..<Memory.pageSize]))
  }
}

// Swift Testing's #expect and #require can't take expressions on a
// ~Copyable value like Arena, so results go into locals first.
@Test func arenasAlignGrowAndReset() throws {
  var arena = try Arena(capacity: 16 << 20)
  let pa = arena.push(3, alignment: 1)
  let a = try #require(pa)
  let pb = arena.push(8, alignment: 64)
  let b = try #require(pb)
  #expect(Int(bitPattern: b) % 64 == 0 && b > a)
  let mark = arena.position
  let pbig = arena.push(1 << 20)  // past the first commit step
  let big = try #require(pbig)
  big.storeBytes(of: 1, toByteOffset: (1 << 20) - 1, as: UInt8.self)
  arena.reset(to: mark)
  let position = arena.position
  #expect(position == mark)
  let reused = arena.push(16)
  #expect(reused == big)
  let tooBig = arena.push(32 << 20)  // beyond the reservation
  #expect(tooBig == nil)
  let pints = arena.push(UInt64.self, count: 4)
  let ints = try #require(pints)
  ints[3] = 9
  #expect(ints[3] == 9)
}

@Test func scratchArenasAvoidTheCallersArena() throws {
  let (first, second): (UnsafeRawPointer, UnsafeRawPointer) = Scratch.with { outer in
    let p = UnsafeRawPointer(outer.push(16)!)
    let q: UnsafeRawPointer = Scratch.with(avoiding: p) { inner in UnsafeRawPointer(inner.push(16)!) }
    return (p, q)
  }
  #expect(abs(first.distance(to: second)) > 1 << 20)  // different arenas
  // Each scratch use is reset when it ends, so the next starts at the same place.
  let again: UnsafeRawPointer = Scratch.with { UnsafeRawPointer($0.push(16)!) }
  #expect(again == first)
}
