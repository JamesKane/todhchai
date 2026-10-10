// SPDX-License-Identifier: BSD-3-Clause

@_exported import Sys
@_exported import IPCWire
@_exported import Trace

/// Declares an IPC library: an enum holding structs, integer-backed enums,
/// error enums (`Int32`, `IPCErrorCode`) and protocols. For each protocol
/// `P` it generates, as members of the enum:
/// - `PClient`: calls the methods over a channel;
/// - `PHandler`: what a server implements (every method but events);
/// - `PServer`: reads requests, calls a handler, replies, sends events;
/// - `PEvent`: the events, as an enum.
///
/// `id` names the library on the wire: protocol `P`'s id is "<id>.P", and
/// method ordinals are hashed from it (docs/wire-format.md). `version` is
/// the library's current version.
@attached(member, names: arbitrary)
public macro IPCLibrary(id: String, version: Int) =
  #externalMacro(module: "IPCMacros", type: "IPCLibraryMacro")

/// A request with no reply.
@attached(peer) public macro oneway() = #externalMacro(module: "IPCMacros", type: "MarkerMacro")

/// A message the server sends unasked.
@attached(peer) public macro event() = #externalMacro(module: "IPCMacros", type: "MarkerMacro")

/// The protocol version that added the method.
@attached(peer) public macro since(_ version: Int) =
  #externalMacro(module: "IPCMacros", type: "MarkerMacro")
