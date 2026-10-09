// SPDX-License-Identifier: BSD-3-Clause

/// A system call's result. The values are the C ABI's `td_status_t`
/// (`c/include/td_kernel.h`), negative like Zircon's, so they can travel in
/// an epitaph.
public enum Status: Int32, Error, Equatable, Sendable {
  case ok = 0
  /// An argument is malformed.
  case invalidArgs = -10
  /// The handle is not valid in this process.
  case badHandle = -11
  /// The handle's object is not of the type the call needs.
  case wrongType = -12
  /// A buffer is too small for the message; nothing was taken.
  case bufferTooSmall = -15
  /// A message or handle count exceeds the limit.
  case outOfRange = -14
  /// A message cannot carry this handle (its own channel, or its peer).
  case notSupported = -2
  /// The deadline passed before a signal was asserted.
  case timedOut = -21
  /// There is nothing to read yet.
  case shouldWait = -22
  /// The handle was closed while waiting on it.
  case canceled = -23
  /// The other end of the channel is closed.
  case peerClosed = -24
  /// The handle lacks a right the call needs.
  case accessDenied = -30
}
