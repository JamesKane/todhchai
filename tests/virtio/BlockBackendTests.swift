// SPDX-License-Identifier: BSD-3-Clause

// The block service's virtio-blk backend (M3i) against the model device:
// blocks through the ring and its bounce region, and a Taisce volume made,
// filled and mounted again on it.

import Block
import BlockRing
import Sys
import Taisce
import Testing
import Virtio

/// Memory the model reaches at this process's own addresses.
final class IdentityDMA: DMAMemory {
  var regions: [UnsafeMutableRawPointer] = []
  deinit { for r in regions { r.deallocate() } }
  func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64) {
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    regions.append(p)
    return (p, UInt64(UInt(bitPattern: p)))
  }
}

/// A backend over a model disk of `sectors`, which serves each request
/// when notified (so `wait` never has to).
func modelBackend(sectors: Int, offer: UInt64 = Feature.version1 | Block.Feature.flush, bounce: Int = 16384)
  throws -> (ModelBlock, VirtioBlockBackend<ModelWindow>, IdentityDMA)
{
  let model = ModelBlock(sectors: sectors, offer: offer)
  let notify = ModelWindow()
  notify.onWrite = { _, _, _ in model.process() }
  let dma = IdentityDMA()
  let backend = try VirtioBlockBackend(device: Device(common: model.common, device: model.config), notify: notify,
                                       multiplier: 4, memory: dma, queueSize: 64, bounceBytes: bounce) {
    Issue.record("waited: the model serves at once")
  }
  return (model, backend, dma)
}

@Test func blocksGoThroughTheRingInChunks() throws {
  let (model, backend, _) = try modelBackend(sectors: 8 * 1024)
  #expect(backend.blockCount == 1024 && backend.blockSize == 4096 && !backend.readOnly)
  #expect(model.queue.size == 8)  // the model's largest: a power of two below 64
  #expect(model.common.bytes[0x14] & DeviceStatus.driverOK != 0)
  // 10 blocks, more than the 16 KiB bounce region: three requests.
  let data = (0..<40960).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
  #expect(data.withUnsafeBytes { backend.write(3, from: $0, policy: .uncached) } == .ok)
  #expect(backend.requests == 3)
  #expect(Array(model.disk[(3 * 4096)..<(13 * 4096)]) == data)
  var back = [UInt8](repeating: 0, count: 40960)
  #expect(back.withUnsafeMutableBytes { backend.read(3, into: $0, policy: .cached) } == .ok)
  #expect(back == data)
  #expect(backend.flush() == .ok && backend.requests == 7)
  #expect(back.withUnsafeMutableBytes { backend.read(1020, into: $0, policy: .cached) } == .outOfRange)
}

/// Taisce's device over a block backend, as the fs service has one over
/// the block service's ring.
struct BackendDevice: BlockDevice {
  let backend: any BlockBackend
  var blockSize: Int { backend.blockSize }
  var blockCount: UInt64 { backend.blockCount }
  mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count * blockSize)
    guard out.withUnsafeMutableBytes({ backend.read(block, into: $0, policy: .cached) }) == .ok else { throw .io(5) }
    return out
  }
  mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.withUnsafeBytes({ backend.write(block, from: $0, policy: .cached) }) == .ok else { throw .io(5) }
  }
  mutating func flush() throws(TaisceError) {
    guard backend.flush() == .ok else { throw .io(5) }
  }
}

@Test func taisceLivesOnTheVirtioDisk() throws {
  let (_, backend, _) = try modelBackend(sectors: 8 * 4096)  // 16 MiB
  var fs = try FileSystem.format(BackendDevice(backend: backend), label: Array("virtio".utf8),
                                 uuid: [UInt8](repeating: 9, count: 16), now: 1)
  let text = Array(String(repeating: "dia duit ", count: 2000).utf8)
  let ino = try fs.create(FileSystem<BackendDevice>.root, Array("note.txt".utf8), .file, mode: 0o644, now: 2)
  try fs.write(ino, offset: 0, text, now: 3)
  try fs.sync()
  let before = backend.requests
  var again = try FileSystem.mount(BackendDevice(backend: backend))
  let found = try again.lookup(FileSystem<BackendDevice>.root, Array("note.txt".utf8))
  #expect(try again.read(found, offset: 0, count: text.count) == text)
  #expect(try again.check() > 0)
  #expect(backend.requests > before)
}
