// SPDX-License-Identifier: BSD-3-Clause

// Arenas (sdk.md §8): reserve a large range once, commit it as the arena
// grows, free everything at once by resetting. Scratch arenas are two per
// thread, so a function can use one while its caller's result lives in the
// other (Ryan Fleury's scheme, studied).

import Glibc

public struct Arena: ~Copyable {
  let reserved: UnsafeMutableRawBufferPointer
  var committed = 0
  var used = 0

  /// Commit grows in steps this big, to keep system calls rare.
  static let commitStep = 64 << 10

  /// An arena of up to `capacity` bytes (address space only, until used).
  public init(capacity: Int = 1 << 30) throws(MemoryError) {
    reserved = try Memory.reserve(capacity)
  }

  deinit { Memory.release(reserved) }

  /// Bytes in use.
  public var position: Int { used }

  /// `bytes` of memory aligned to `alignment`, zeroed if never used
  /// before, valid until the arena is reset past it. Nil if the arena is
  /// full.
  public mutating func push(_ bytes: Int, alignment: Int = 16) -> UnsafeMutableRawPointer? {
    let start = (used + alignment - 1) & ~(alignment - 1)
    let end = start + bytes
    guard end <= reserved.count else { return nil }
    if end > committed {
      let target = min(reserved.count, (end + Self.commitStep - 1) & ~(Self.commitStep - 1))
      let range = UnsafeMutableRawBufferPointer(rebasing: reserved[committed..<target])
      guard (try? Memory.commit(range)) != nil else { return nil }
      committed = target
    }
    used = end
    return reserved.baseAddress! + start
  }

  /// Room for `count` values of `T`.
  public mutating func push<T>(_: T.Type, count: Int) -> UnsafeMutableBufferPointer<T>? {
    guard let p = push(MemoryLayout<T>.stride * count, alignment: MemoryLayout<T>.alignment) else { return nil }
    return UnsafeMutableBufferPointer(start: p.bindMemory(to: T.self, capacity: count), count: count)
  }

  /// Frees everything pushed after `position` (from an earlier `position`).
  public mutating func reset(to position: Int = 0) {
    used = min(used, max(0, position))
  }

  /// Whether `pointer` lies inside this arena's reservation.
  public func contains(_ pointer: UnsafeRawPointer) -> Bool {
    let base = UnsafeRawPointer(reserved.baseAddress!)
    return pointer >= base && pointer < base + reserved.count
  }
}

/// Two scratch arenas per thread.
public enum Scratch {
  final class Pair {
    var first: Arena
    var second: Arena
    /// The first arena's range, kept apart from it: a nested `with` checks
    /// for a conflict while the outer one still has `first` borrowed.
    let firstRange: UnsafeMutableRawBufferPointer
    init() throws(MemoryError) {
      first = try Arena()
      second = try Arena()
      firstRange = first.reserved
    }
  }

  nonisolated(unsafe) static var key: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key) { Unmanaged<Pair>.fromOpaque($0!).release() }
    return key
  }()

  /// Runs `body` with a scratch arena that doesn't hold `conflict` (pass
  /// the caller's arena when results go there), reset afterwards.
  public static func with<R, E: Error>(avoiding conflict: UnsafeRawPointer? = nil,
                                       _ body: (inout Arena) throws(E) -> R) throws(E) -> R {
    let pair: Pair
    if let p = pthread_getspecific(key) {
      pair = Unmanaged<Pair>.fromOpaque(p).takeUnretainedValue()
    } else {
      guard let made = try? Pair() else { fatalError("Scratch: can't reserve address space for scratch arenas") }
      pair = made
      pthread_setspecific(key, Unmanaged.passRetained(pair).toOpaque())
    }
    if let conflict, let base = pair.firstRange.baseAddress,
      conflict >= UnsafeRawPointer(base), conflict < UnsafeRawPointer(base) + pair.firstRange.count
    {
      let mark = pair.second.position
      defer { pair.second.reset(to: mark) }
      return try body(&pair.second)
    }
    let mark = pair.first.position
    defer { pair.first.reset(to: mark) }
    return try body(&pair.first)
  }
}
