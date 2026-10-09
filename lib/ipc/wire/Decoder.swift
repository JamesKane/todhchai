// SPDX-License-Identifier: BSD-3-Clause

/// Reads one message in place, allocating nothing. The message is
/// untrusted: every read is bounds-checked, every padding byte must be
/// zero, and `finish` fails if any byte or handle is left over.
///
/// Byte strings come back as `RawSpan` views into the message, so decoding
/// copies nothing.
public struct Decoder: ~Copyable, ~Escapable {
  let bytes: RawSpan
  let handles: Span<UInt32>
  public let header: MessageHeader
  var nextHandle = 0
  var bodyStart = MessageHeader.size
  var inlineSize = 0
  var next = MessageHeader.size

  @_lifetime(copy bytes, copy handles)
  public init(bytes: RawSpan, handles: Span<UInt32>) throws(WireError) {
    guard bytes.byteCount <= maxMessageBytes, bytes.byteCount % wireAlignment == 0 else {
      throw bytes.byteCount > maxMessageBytes ? .tooLarge : .truncated
    }
    guard handles.count <= maxMessageHandles else { throw .tooManyHandles }
    self.header = try MessageHeader(from: bytes)
    self.bytes = bytes
    self.handles = handles
  }

  /// Takes the body's inline part, which must be there in full.
  @_lifetime(self: copy self)
  public mutating func beginBody(inlineSize: Int) throws(WireError) {
    self.inlineSize = wireAligned(inlineSize)
    guard next + self.inlineSize <= bytes.byteCount else { throw .truncated }
    next += self.inlineSize
  }

  /// An integer in the inline part, at `offset` from its start.
  public func load<T: FixedWidthInteger & ConvertibleFromBytes>(_: T.Type, at offset: Int)
    throws(WireError) -> T
  {
    guard offset >= 0, offset + MemoryLayout<T>.size <= inlineSize else { throw .outOfBounds }
    return bytes.load(fromByteOffset: bodyStart + offset, as: T.self, .littleEndian)
  }

  /// Checks that the inline part's padding in `offset..<offset+count` is zero.
  public func checkPadding(at offset: Int, count: Int) throws(WireError) {
    guard offset >= 0, offset + count <= inlineSize else { throw .outOfBounds }
    for i in 0..<count where bytes.load(fromByteOffset: bodyStart + offset + i, as: UInt8.self) != 0 {
      throw .nonzeroPadding
    }
  }

  /// The byte string stored at `offset`, as a view into the message. Out-of-
  /// line data must be taken in the order it was stored.
  @_lifetime(copy self)
  public mutating func loadBytes(at offset: Int) throws(WireError) -> RawSpan {
    let count = try load(UInt64.self, at: offset)
    guard try load(UInt64.self, at: offset + 8) == presentMarker else { throw .badPresence }
    guard count <= UInt64(bytes.byteCount - next) else { throw .truncated }
    let start = next
    let padded = wireAligned(Int(count))
    guard start + padded <= bytes.byteCount else { throw .truncated }
    for i in (start + Int(count))..<(start + padded)
    where bytes.load(fromByteOffset: i, as: UInt8.self) != 0 {
      throw .nonzeroPadding
    }
    next += padded
    return bytes.extracting(start..<(start + Int(count)))
  }

  /// The handle whose presence marker is at `offset`: the next one in the
  /// side array, or `nil` when the marker says absent.
  @_lifetime(self: copy self)
  public mutating func loadHandle(at offset: Int) throws(WireError) -> UInt32? {
    switch try load(UInt32.self, at: offset) {
    case 0: return nil
    case UInt32.max:
      guard nextHandle < handles.count else { throw .missingHandle }
      defer { nextHandle += 1 }
      return handles[nextHandle]
    default: throw .badPresence
    }
  }

  /// Checks that every byte and every handle was consumed.
  public func finish() throws(WireError) {
    guard next == bytes.byteCount, nextHandle == handles.count else { throw .unconsumed }
  }
}
