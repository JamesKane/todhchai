// SPDX-License-Identifier: BSD-3-Clause

// The functions under their C names, for native processes (M3): the Swift
// runtime and compiled code call memcpy and friends by symbol. Built only
// for croi's targets, with LLVM's loop-idiom recognition off (CMakeLists),
// so the loops behind these can't become calls to themselves. The hosted
// build keeps the host's libc.

@c(memcpy) public func exportedMemcpy(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt)
  -> UnsafeMutableRawPointer
{ unsafe memcpy(d, s, n) }

@c(memmove) public func exportedMemmove(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt)
  -> UnsafeMutableRawPointer
{ unsafe memmove(d, s, n) }

@c(memset) public func exportedMemset(_ s: UnsafeMutableRawPointer, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer {
  unsafe memset(s, c, n)
}

@c(memcmp) public func exportedMemcmp(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ n: UInt) -> Int32 {
  unsafe memcmp(a, b, n)
}

@c(bcmp) public func exportedBcmp(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ n: UInt) -> Int32 {
  unsafe bcmp(a, b, n)
}

@c(memchr) public func exportedMemchr(_ s: UnsafeRawPointer, _ c: Int32, _ n: UInt) -> UnsafeRawPointer? {
  unsafe memchr(s, c, n)
}

@c(strlen) public func exportedStrlen(_ s: UnsafePointer<CChar>) -> UInt { unsafe strlen(s) }

@c(strnlen) public func exportedStrnlen(_ s: UnsafePointer<CChar>, _ n: UInt) -> UInt { unsafe strnlen(s, n) }

@c(strcmp) public func exportedStrcmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 {
  unsafe strcmp(a, b)
}

@c(strncmp) public func exportedStrncmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>, _ n: UInt) -> Int32 {
  unsafe strncmp(a, b, n)
}
