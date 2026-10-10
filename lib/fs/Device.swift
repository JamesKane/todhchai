// SPDX-License-Identifier: BSD-3-Clause

// Taisce's BlockDevice over a block service session: the fs service's
// volume, through the ring (architecture §11).

import Block
import BlockRing
import Glibc
import Taisce

/// A session's client, shared by copies of the device (Taisce copies
/// devices; the session is one).
final class SessionBox {
  var client: BlockClient
  init(_ client: consuming BlockClient) { self.client = client }
}

public struct RingDevice: BlockDevice {
  let box: SessionBox
  public let blockSize: Int
  public let blockCount: UInt64

  /// A device over `client`'s session; Taisce's blocks must be the device's.
  public init(_ client: consuming BlockClient) throws(TaisceError) {
    guard Int(client.info.blockSize) == Layout.blockSize else { throw .outOfRange }
    blockSize = Int(client.info.blockSize)
    blockCount = client.info.blockCount
    box = SessionBox(client)
  }

  static func taisce(_ s: BlockStatus) -> TaisceError {
    switch s {
    case .outOfRange: .outOfRange
    case .readOnly: .readOnly
    default: .io(EIO)
    }
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    guard count >= 0, block <= blockCount, UInt64(count) <= blockCount - block else { throw .outOfRange }
    do throws(BlockStatus) { return try box.client.read(block, count: count) } catch { throw Self.taisce(error) }
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0, block <= blockCount, UInt64(bytes.count / blockSize) <= blockCount - block
    else { throw .outOfRange }
    do throws(BlockStatus) { try box.client.write(block, bytes) } catch { throw Self.taisce(error) }
  }

  public mutating func flush() throws(TaisceError) {
    do throws(BlockStatus) { try box.client.flush() } catch { throw Self.taisce(error) }
  }
}
