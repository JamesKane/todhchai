// SPDX-License-Identifier: BSD-3-Clause

// A ramdisk: blocks in a VMO mapped into the service (M3e, natively until
// virtio-blk). Unlike MemoryBackend's array, nothing is zeroed or touched
// up front: a page costs a fault the first time it is used, so a large
// disk starts at once. Tier 0.

import BlockRing
import Sys

/// Blocks in a VMO of their own, for as long as the backend lives.
public final class VMOBackend: BlockBackend {
  public let blockSize: Int
  public let blockCount: UInt64
  public let readOnly = false
  let mapping: Mapping

  public init(blocks: UInt64, blockSize: Int = 4096) throws(Status) {
    self.blockSize = blockSize
    blockCount = blocks
    let vmo = try VMO.create(size: Int(blocks) * blockSize)
    mapping = try VMO.map(vmo, length: Int(blocks) * blockSize)
  }

  public func read(_ block: UInt64, into buffer: UnsafeMutableRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let start = Int(block) * blockSize
    guard start + buffer.count <= mapping.length else { return .outOfRange }
    unsafe buffer.copyMemory(from: UnsafeRawBufferPointer(start: mapping.address + start, count: buffer.count))
    return .ok
  }

  public func write(_ block: UInt64, from buffer: UnsafeRawBufferPointer, policy: CachePolicy) -> BlockStatus {
    let start = Int(block) * blockSize
    guard start + buffer.count <= mapping.length else { return .outOfRange }
    unsafe UnsafeMutableRawBufferPointer(start: mapping.address + start, count: buffer.count).copyMemory(from: buffer)
    return .ok
  }

  public func flush() -> BlockStatus { .ok }
}
