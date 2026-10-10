// SPDX-License-Identifier: BSD-3-Clause

// Sys's calls in the Embedded build until croi's syscalls take their place
// (M3): every call fails with `notSupported`. It exists so the services'
// tier 0 code is compiled as Embedded Swift now, which proves it clean.

/// A program's entry: natively, an ELF file in a VMO (M3d).
public struct ProgramEntry: Sendable {
  public let image: UInt32
  public let offset: Int
  public let length: Int
  public let name: String
  public init(image: UInt32, offset: Int, length: Int, name: String) {
    self.image = image
    self.offset = offset
    self.length = length
    self.name = name
  }
}

enum Kernel {
  static func close(_ h: UInt32) {}
  static func duplicate(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 { throw .notSupported }
  static func replace(_ h: UInt32, _ r: Rights) throws(Status) -> UInt32 { throw .notSupported }
  static func info(_ h: UInt32) throws(Status) -> HandleInfo { throw .notSupported }
  static func signal(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) { throw .notSupported }
  static func signalPeer(_ h: UInt32, _ clear: UInt32, _ set: UInt32) throws(Status) { throw .notSupported }
  static func wait(_ h: UInt32, _ signals: UInt32, _ deadline: Int64) throws(Status) -> UInt32 { throw .notSupported }
  static func waitAsync(_ h: UInt32, _ port: UInt32, _ key: UInt64, _ signals: UInt32, _ edge: Bool) throws(Status) {
    throw .notSupported
  }
  static func channelCreate() throws(Status) -> (UInt32, UInt32) { throw .notSupported }
  static func channelWrite(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32]) throws(Status) { throw .notSupported }
  static func channelRead(_ h: UInt32) throws(Status) -> Channel.Message { throw .notSupported }
  static func channelCall(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32], _ deadline: Int64) throws(Status)
    -> Channel.Message
  { throw .notSupported }
  static func eventCreate() throws(Status) -> UInt32 { throw .notSupported }
  static func eventPairCreate() throws(Status) -> (UInt32, UInt32) { throw .notSupported }
  static func portCreate() throws(Status) -> UInt32 { throw .notSupported }
  static func portQueue(_ p: UInt32, _ packet: Packet) throws(Status) { throw .notSupported }
  static func portWait(_ p: UInt32, _ deadline: Int64) throws(Status) -> Packet { throw .notSupported }
  static func portCancel(_ p: UInt32, _ source: UInt32, _ key: UInt64) throws(Status) { throw .notSupported }
  static func vmoCreate(_ size: Int) throws(Status) -> UInt32 { throw .notSupported }
  static func vmoSize(_ h: UInt32) throws(Status) -> Int { throw .notSupported }
  static func vmoRead(_ h: UInt32, _ offset: Int, _ count: Int) throws(Status) -> [UInt8] { throw .notSupported }
  static func vmoWrite(_ h: UInt32, _ offset: Int, _ bytes: [UInt8]) throws(Status) { throw .notSupported }
  static func vmoMap(_ h: UInt32, _ offset: Int, _ length: Int, _ writable: Bool) throws(Status) -> UnsafeMutableRawPointer {
    throw .notSupported
  }
  static func vmoUnmap(_ address: UnsafeMutableRawPointer, _ length: Int) {}
  static func processSelf() throws(Status) -> UInt32 { throw .notSupported }
  static func realtime() -> Int64 { 0 }
  static func futexWait(_ address: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64) throws(Status) {
    throw .notSupported
  }
  static func futexWake(_ address: UnsafeMutablePointer<UInt32>, count: Int) {}
  static func timerCreate() throws(Status) -> UInt32 { throw .notSupported }
  static func timerSet(_ h: UInt32, _ deadline: Int64) throws(Status) { throw .notSupported }
  static func timerCancel(_ h: UInt32) throws(Status) { throw .notSupported }
  static func jobCreate(_ parent: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func processCreate(_ job: UInt32, _ name: String) throws(Status) -> UInt32 { throw .notSupported }
  static func threadCreate(_ process: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func processStart(_ process: UInt32, _ thread: UInt32, _ arg: UInt32, _ entry: ProgramEntry,
                           _ extra: [(info: UInt32, handle: UInt32)]) throws(Status) { throw .notSupported }
  static func threadStart(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) { throw .notSupported }
  static func kill(_ h: UInt32) throws(Status) { throw .notSupported }
  static func exit(_ code: Int64) -> Never { fatalError("process_exit: no kernel") }
  static func processInfo(_ h: UInt32) throws(Status) -> ProcessInfo { throw .notSupported }
  static func now() -> Int64 { 0 }
  static func sleep(_ deadline: Int64) {}
}
