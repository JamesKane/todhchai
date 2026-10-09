// SPDX-License-Identifier: BSD-3-Clause

/// What can go wrong in Taisce. Tier 0: no strings, so every case says
/// what it is by itself.
public enum TaisceError: Error, Equatable, Sendable {
  /// The device failed (errno on the host).
  case io(Int32)
  /// A block number past the end of the device, or a buffer that isn't
  /// whole blocks.
  case outOfRange
  /// No superblock copy is valid: not a Taisce volume, or both copies are damaged.
  case notAVolume
  /// A version this code doesn't read.
  case unsupportedVersion(UInt32)
  /// The device is too small for the layout asked for.
  case tooSmall
  /// There isn't enough free space.
  case noSpace
  /// On-disk structures disagree (what was found is the case's name).
  case corrupt(Corruption)
  /// A key or value larger than a node allows (BTree.maxKey, maxValue).
  case tooLarge
}

public enum Corruption: Equatable, Sendable {
  case superblockLayout
  case bitmapSize
  case node
  /// A tree breaks an invariant (BTree.check says which).
  case tree(TreeFault)
}

public enum TreeFault: Equatable, Sendable {
  case keysOutOfOrder
  case keyOutsideItsBounds
  case uneven  // leaves at different depths
  case underfull
  case overfull
  case childCount
  case blockNotAllocated
}
