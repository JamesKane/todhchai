// SPDX-License-Identifier: BSD-3-Clause

/// Writes one message into caller-provided storage, allocating nothing.
///
/// A body has a fixed-size inline part, whose layout the caller (generated
/// code) knows, followed by out-of-line data in the order it is stored
/// (FIDL's rule). Every part starts 8-byte aligned, and every padding byte
/// is zero. Handles go into a side array; the body holds a presence marker.
///
///     var e = Encoder(bytes: buffer, handles: handleBuffer)
///     try e.header(MessageHeader(txid: 1, kind: .request, ordinal: o))
///     try e.beginBody(inlineSize: 24)
///     try e.store(UInt32(7), at: 0)
///     try e.storeBytes(name, at: 8)
///     let (byteCount, handleCount) = e.finish()
public struct Encoder: ~Copyable, ~Escapable {
  var bytes: MutableRawSpan
  var handles: MutableSpan<UInt32>
  var handleCount = 0
  var bodyStart = MessageHeader.size
  var inlineSize = 0
  var end = 0

  @_lifetime(copy bytes, copy handles)
  public init(bytes: consuming MutableRawSpan, handles: consuming MutableSpan<UInt32>) {
    self.bytes = bytes
    self.handles = handles
  }

  /// Writes the header. It comes first, and a message with no body is done.
  @_lifetime(self: copy self)
  public mutating func header(_ header: MessageHeader) throws(WireError) {
    guard bytes.byteCount >= MessageHeader.size else { throw .tooLarge }
    header.store(into: &bytes)
    end = MessageHeader.size
  }

  /// Reserves the body's inline part, zeroed, after the header.
  @_lifetime(self: copy self)
  public mutating func beginBody(inlineSize: Int) throws(WireError) {
    self.inlineSize = wireAligned(inlineSize)
    try reserve(self.inlineSize)
  }

  /// Stores an integer in the inline part, at `offset` from its start.
  @_lifetime(self: copy self)
  public mutating func store<T: FixedWidthInteger & BitwiseCopyable & ConvertibleToBytes>(_ value: T, at offset: Int)
    throws(WireError)
  {
    guard offset >= 0, offset + MemoryLayout<T>.size <= inlineSize else { throw .outOfBounds }
    bytes.storeBytes(of: value, toByteOffset: bodyStart + offset, as: T.self, .littleEndian)
  }

  /// Stores a byte string: 16 inline bytes at `offset` (the count, then the
  /// presence marker), and the bytes out of line.
  @_lifetime(self: copy self)
  public mutating func storeBytes(_ data: RawSpan, at offset: Int) throws(WireError) {
    try store(UInt64(data.byteCount), at: offset)
    try store(presentMarker, at: offset + 8)
    let start = end
    try reserve(wireAligned(data.byteCount))
    for i in 0..<data.byteCount {
      bytes.storeBytes(of: data.load(fromByteOffset: i, as: UInt8.self), toByteOffset: start + i, as: UInt8.self)
    }
  }

  /// Moves a handle into the message: a 4-byte presence marker inline at
  /// `offset`, and the handle in the side array. `nil` stores "absent".
  @_lifetime(self: copy self)
  public mutating func storeHandle(_ handle: UInt32?, at offset: Int) throws(WireError) {
    guard let handle else { return try store(UInt32(0), at: offset) }
    guard handleCount < handles.count, handleCount < maxMessageHandles else { throw .tooManyHandles }
    try store(UInt32.max, at: offset)
    handles[handleCount] = handle
    handleCount += 1
  }

  /// The message's size in bytes, and the number of handles it carries.
  public func finish() -> (byteCount: Int, handleCount: Int) { (end, handleCount) }

  /// Zeroes `count` bytes at the end and moves past them.
  @_lifetime(self: copy self)
  mutating func reserve(_ count: Int) throws(WireError) {
    guard end + count <= bytes.byteCount, end + count <= maxMessageBytes else { throw .tooLarge }
    for i in end..<(end + count) { bytes.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self) }
    end += count
  }
}

/// The presence marker of an out-of-line object that is there.
let presentMarker = UInt64.max
