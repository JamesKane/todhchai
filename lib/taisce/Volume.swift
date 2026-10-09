// SPDX-License-Identifier: BSD-3-Clause

/// A Taisce volume on a device: its superblock and free space. Later steps
/// hang the tree, the log and the journal off it.
public struct Volume<Device: BlockDevice>: ~Copyable {
  public var device: Device
  public private(set) var superblock: Superblock
  public var allocator: Allocator

  /// Makes a new, empty volume on `device`.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64,
                            logBlocks: UInt64? = nil) throws(TaisceError) -> Volume {
    guard device.blockSize == Layout.blockSize else { throw .outOfRange }
    let layout = try Layout(blockCount: device.blockCount, logBlocks: logBlocks)
    var allocator = Allocator(blockCount: layout.blockCount, reserved: layout.dataStart)
    // An empty log and bitmap, then both superblock copies.
    let zero = [UInt8](repeating: 0, count: Layout.blockSize)
    for b in layout.logStart..<layout.dataStart { try device.write(b, zero) }
    for (index, bytes) in allocator.dirtyBlocks() { try device.write(layout.bitmapStart + index, bytes) }
    try device.flush()
    // Both copies, each where its generation says, as every commit does.
    var superblock = Superblock(layout: layout, uuid: uuid, label: label, createdNs: now)
    try device.write(superblock.slot, superblock.encode())
    superblock.generation += 1
    try device.write(superblock.slot, superblock.encode())
    try device.flush()
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  /// Opens the volume on `device`: the newest valid superblock wins.
  public static func open(_ device: consuming Device) throws(TaisceError) -> Volume {
    guard device.blockSize == Layout.blockSize, device.blockCount >= 2 else { throw .notAVolume }
    var newest: Superblock?
    for b: UInt64 in 0..<2 {
      guard let s = try Superblock.decode(device.read(b, count: 1)) else { continue }
      if newest.map({ s.generation > $0.generation }) ?? true { newest = s }
    }
    guard let superblock = newest else { throw .notAVolume }
    guard superblock.layout.blockCount <= device.blockCount else { throw .corrupt(.superblockLayout) }
    let layout = superblock.layout
    let bitmap = try device.read(layout.bitmapStart, count: Int(layout.bitmapBlocks))
    let allocator = try Allocator(blockCount: layout.blockCount, bitmap: bitmap)
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  init(device: consuming Device, superblock: Superblock, allocator: Allocator) {
    self.device = device
    self.superblock = superblock
    self.allocator = allocator
  }

  /// Writes the changed bitmap blocks and a new superblock generation,
  /// with a barrier between: the superblock never names state that isn't
  /// on disk yet. (S0c puts this behind the log.)
  public mutating func commit(_ update: (inout Superblock) -> Void = { _ in }) throws(TaisceError) {
    for (index, bytes) in allocator.dirtyBlocks() { try device.write(superblock.layout.bitmapStart + index, bytes) }
    try device.flush()
    update(&superblock)
    superblock.generation += 1
    try device.write(superblock.slot, superblock.encode())
    try device.flush()
  }
}
