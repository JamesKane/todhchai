// SPDX-License-Identifier: BSD-3-Clause

/// Why a message could not be encoded or decoded. Decoding treats every
/// message as untrusted: any of these means the peer broke the protocol.
public enum WireError: Error, Equatable {
  /// The buffer ends before the data it must hold.
  case truncated
  /// The message is larger than `maxMessageBytes`, or the encoder ran out
  /// of buffer.
  case tooLarge
  /// The header's wire version is not one this code speaks.
  case unsupportedVersion
  /// The header's kind byte is not a `MessageKind`.
  case unknownKind
  /// Reserved header flags are set.
  case reservedFlags
  /// A body field lies outside the inline part.
  case outOfBounds
  /// A presence marker is neither "absent" nor "present".
  case badPresence
  /// A padding byte is not zero.
  case nonzeroPadding
  /// More handles than `maxMessageHandles`, or than the handle buffer holds.
  case tooManyHandles
  /// The body marks a handle present, but the side array has no more.
  case missingHandle
  /// Bytes or handles are left over after decoding.
  case unconsumed
}
