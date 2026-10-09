// SPDX-License-Identifier: BSD-3-Clause

// The C ABI over the hosted kernel: the declarations are in
// c/include/td_kernel.h, written by hand to match.

@c public func td_handle_close(_ handle: UInt32) -> Int32 {
  status { () throws(Status) in try HostKernel.shared.close(handle) }
}

@c public func td_channel_create(_ out0: UnsafeMutablePointer<UInt32>?, _ out1: UnsafeMutablePointer<UInt32>?)
  -> Int32
{
  guard let out0, let out1 else { return Status.invalidArgs.rawValue }
  return status { () throws(Status) in
    (out0.pointee, out1.pointee) = try HostKernel.shared.channelCreate()
  }
}

@c public func td_channel_write(
  _ handle: UInt32, _ bytes: UnsafeRawPointer?, _ byteCount: UInt32,
  _ handles: UnsafePointer<UInt32>?, _ handleCount: UInt32
) -> Int32 {
  guard byteCount == 0 || bytes != nil, handleCount == 0 || handles != nil else {
    return Status.invalidArgs.rawValue
  }
  let b = byteCount == 0 ? [] : Array(UnsafeRawBufferPointer(start: bytes, count: Int(byteCount)))
  let h = handleCount == 0 ? [] : Array(UnsafeBufferPointer(start: handles, count: Int(handleCount)))
  return status { () throws(Status) in try HostKernel.shared.channelWrite(handle, bytes: b, handles: h) }
}

@c public func td_channel_read(
  _ handle: UInt32, _ bytes: UnsafeMutableRawPointer?, _ byteCapacity: UInt32,
  _ actualBytes: UnsafeMutablePointer<UInt32>?, _ handles: UnsafeMutablePointer<UInt32>?,
  _ handleCapacity: UInt32, _ actualHandles: UnsafeMutablePointer<UInt32>?
) -> Int32 {
  let b = UnsafeMutableRawBufferPointer(start: byteCapacity == 0 ? nil : bytes, count: Int(byteCapacity))
  let h = UnsafeMutableBufferPointer(start: handleCapacity == 0 ? nil : handles, count: Int(handleCapacity))
  if (byteCapacity != 0 && bytes == nil) || (handleCapacity != 0 && handles == nil) {
    return Status.invalidArgs.rawValue
  }
  do {
    let got = try HostKernel.shared.channelRead(handle, bytes: b, handles: h)
    actualBytes?.pointee = UInt32(got.byteCount)
    actualHandles?.pointee = UInt32(got.handleCount)
    return Status.ok.rawValue
  } catch {
    actualBytes?.pointee = UInt32(error.needed.byteCount)
    actualHandles?.pointee = UInt32(error.needed.handleCount)
    return error.status.rawValue
  }
}

@c public func td_event_create(_ out: UnsafeMutablePointer<UInt32>?) -> Int32 {
  guard let out else { return Status.invalidArgs.rawValue }
  return status { () throws(Status) in out.pointee = try HostKernel.shared.eventCreate() }
}

@c public func td_object_signal(_ handle: UInt32, _ clear: UInt32, _ set: UInt32) -> Int32 {
  status { () throws(Status) in try HostKernel.shared.signal(handle, clear: clear, set: set) }
}

@c public func td_object_wait_one(
  _ handle: UInt32, _ signals: UInt32, _ deadline: Int64, _ observed: UnsafeMutablePointer<UInt32>?
) -> Int32 {
  do {
    observed?.pointee = try HostKernel.shared.wait(handle, for: signals, deadline: deadline)
    return Status.ok.rawValue
  } catch {
    observed?.pointee = error.observed
    return error.status.rawValue
  }
}

@c public func td_clock_monotonic() -> Int64 { HostKernel.now() }

/// Runs a call and returns its status code.
func status(_ body: () throws(Status) -> Void) -> Int32 {
  do {
    try body()
    return Status.ok.rawValue
  } catch {
    return error.rawValue
  }
}
