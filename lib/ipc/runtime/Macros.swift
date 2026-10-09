// SPDX-License-Identifier: BSD-3-Clause

@_exported import IPCHost
@_exported import IPCWire

/// Declares an IPC protocol. From the protocol it generates:
/// - `<Name>Client`: calls the methods over a channel;
/// - `<Name>Handler`: what a server implements (every method but events);
/// - `<Name>Server`: reads requests, calls a handler, replies, sends events;
/// - `<Name>Event`: the events, as an enum.
///
/// `id` names the protocol on the wire; method ordinals are hashed from it
/// (docs/wire-format.md). `version` is the protocol's current version.
@attached(peer, names: suffixed(Client), suffixed(Server), suffixed(Handler), suffixed(Event))
public macro IPCProtocol(id: String, version: Int) =
  #externalMacro(module: "IPCMacros", type: "IPCProtocolMacro")

/// A request with no reply.
@attached(peer) public macro oneway() = #externalMacro(module: "IPCMacros", type: "MarkerMacro")

/// A message the server sends unasked.
@attached(peer) public macro event() = #externalMacro(module: "IPCMacros", type: "MarkerMacro")

/// The protocol version that added the method.
@attached(peer) public macro since(_ version: Int) =
  #externalMacro(module: "IPCMacros", type: "MarkerMacro")
