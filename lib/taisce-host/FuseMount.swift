// SPDX-License-Identifier: BSD-3-Clause

// Mounting without root, as libfuse does but without libfuse: the setuid
// fusermount3 (a host tool, S0 decision 1) opens /dev/fuse, mounts it, and
// passes the descriptor back over a socket named by _FUSE_COMMFD. With
// auto_unmount it stays behind and unmounts if this process dies.

import Glibc
import Synchronization
import Taisce
import TDLinux

let stopRequested = Atomic<Bool>(false)

final class MountpointBox: @unchecked Sendable {
  let mountpoint: String
  init(_ m: String) { mountpoint = m }
}
func onSignal(_: Int32) { stopRequested.store(true, ordering: .relaxed) }

public enum FuseMount {
  /// Mounts at `mountpoint` and returns the /dev/fuse descriptor to serve.
  public static func mount(_ mountpoint: String, name: String) throws(TaisceHostError) -> Int32 {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0 else { throw .system("socketpair", errno) }
    let ours = pair[0], theirs = pair[1]  // theirs is inherited; ours isn't
    _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
    defer { close(ours) }
    let options = "fsname=\(name),subtype=taisce,default_permissions,auto_unmount"
    // (SIGCHLD must not be ignored here: fusermount3 inherits that and its
    // own waitpid fails.)
    let (status, pid) = spawn(["fusermount3", "-o", options, "--", mountpoint], environment: ["_FUSE_COMMFD=\(theirs)"])
    close(theirs)
    guard status == 0 else { throw .system("spawning fusermount3", status) }
    let fd = td_linux_receive_fd(ours)
    let failure = errno
    // With auto_unmount it stays running until this process lets go of the
    // descriptor, then unmounts and exits: reap it then, off this thread.
    reap(pid)
    guard fd >= 0 else { throw .system("fusermount3 passed no /dev/fuse (is the mountpoint usable?)", failure) }
    return fd
  }

  /// Serves until unmounted. SIGINT or SIGTERM unmounts (the kernel then
  /// lets go, the loop ends, and the server commits). The handler only
  /// sets a flag: a thread watches it, outside any actor.
  public static func serve<D: BlockDevice>(_ server: FuseServer<D>, at mountpoint: String) {
    for sig in [SIGINT, SIGTERM] { signal(sig, onSignal) }
    var thread = pthread_t()
    let box = Unmanaged.passRetained(MountpointBox(mountpoint)).toOpaque()
    if pthread_create(&thread, nil, { arg in
      let mountpoint = Unmanaged<MountpointBox>.fromOpaque(arg!).takeRetainedValue().mountpoint
      while !stopRequested.load(ordering: .relaxed) { usleep(100_000) }
      FuseMount.unmount(mountpoint)
      return nil
    }, box) == 0 {
      pthread_detach(thread)
    }
    server.serve()
  }

  /// Unmounts (fusermount3 -u).
  public static func unmount(_ mountpoint: String) {
    let (status, pid) = spawn(["fusermount3", "-u", "-z", mountpoint], environment: [])
    var exit: Int32 = 0
    if status == 0 { waitpid(pid, &exit, 0) }
  }

  /// Waits for `pid` on a detached thread, so it never lingers as a zombie.
  static func reap(_ pid: pid_t) {
    final class Box: @unchecked Sendable {
      let pid: pid_t
      init(_ pid: pid_t) { self.pid = pid }
    }
    var thread = pthread_t()
    let box = Unmanaged.passRetained(Box(pid)).toOpaque()
    if pthread_create(&thread, nil, { arg in
      let pid = Unmanaged<Box>.fromOpaque(arg!).takeRetainedValue().pid
      var status: Int32 = 0
      waitpid(pid, &status, 0)
      return nil
    }, box) == 0 {
      pthread_detach(thread)
    }
  }

  /// Starts `arguments` from PATH with `environment` added: 0 or an errno,
  /// and the child.
  static func spawn(_ arguments: [String], environment: [String]) -> (Int32, pid_t) {
    var env = environment
    var i = 0
    while let e = environ[i] {
      env.append(String(cString: e))
      i += 1
    }
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = env.map { strdup($0) } + [nil]
    defer {
      for p in argv { free(p) }
      for p in envp { free(p) }
    }
    var pid: pid_t = 0
    let status = posix_spawnp(&pid, arguments[0], nil, nil, argv, envp)
    return (status, pid)
  }
}

public enum TaisceHostError: Error, CustomStringConvertible {
  case system(String, Int32)

  public var description: String {
    switch self {
    case .system(let what, let e): "\(what): \(String(cString: strerror(e)))"
    }
  }
}
