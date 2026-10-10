// SPDX-License-Identifier: BSD-3-Clause

// td boot: Todhchai on croi in QEMU (M3).
//
//   td boot [--arch amd64|arm64|rv64] [--test] [--timeout S] [--next PROGRAM]
//           [--manifests DIR] [--cmdline WORDS] [--keep-croi] [-- QEMU ARGS]
//
// Builds croi's loader and kernel from ../croi as it is checked out (M3
// decided: no pin) into build/croi/<arch>, and our native tree
// (build/native-<arch>). Writes a bootfs holding every program the native
// build made (bin/<name>), and lays out an EFI system partition in
// build/boot/<arch>/esp with croi's loader and kernel, the bootfs, and a
// command line that has userboot start PROGRAM (bin/launcher), plus WORDS
// (such as launcher.until=SERVICE). bootfs also holds DIR's manifests as
// etc/manifests/NAME.manifest, for the launcher. Then boots
// it: interactively on the terminal, or with --test headless, judged by
// userboot's report that the program exited with 0. Logs, the console
// included, are in bench/out/boot/<arch>/. amd64 uses KVM when /dev/kvm
// is usable.

import Bench
import Bootfs
import TraceReader
import FoundationEssentials
import Glibc

struct BootOptions {
  var arch = "amd64"
  var test = false
  var timeout = 60.0
  var next = "bin/launcher"
  var manifests: String?
  var cmdline: [String] = []
  /// Boot the croi last built here instead of building it again: croi is
  /// edited beside us, and its tree may not build at the moment.
  var keepCroi = false
  var qemuArgs: [String] = []
}

func bootCommand(_ args: [String]) -> Bool {
  var o = BootOptions()
  var i = 0
  while i < args.count {
    func value() -> String {
      i += 1
      guard i < args.count else { fail("\(args[i - 1]) needs a value") }
      return args[i]
    }
    switch args[i] {
    case "--arch": o.arch = value()
    case "--test": o.test = true
    case "--timeout":
      guard let t = Double(value()), t > 0 else { fail("--timeout needs seconds") }
      o.timeout = t
    case "--next": o.next = value()
    case "--manifests": o.manifests = value()
    case "--cmdline": o.cmdline += value().split(separator: " ").map(String.init)
    case "--keep-croi": o.keepCroi = true
    case "--":
      o.qemuArgs = Array(args[(i + 1)...])
      i = args.count
    default: fail("unknown option \(args[i]); usage: td boot [--arch A] [--test] [--timeout S] [--next P] [--manifests DIR] [--cmdline WORDS] [--keep-croi] [-- QEMU ARGS]")
    }
    i += 1
  }
  guard ["amd64", "arm64", "rv64"].contains(o.arch) else { fail("--arch is amd64, arm64 or rv64") }
  return boot(o)
}

func boot(_ o: BootOptions) -> Bool {
  let logs = "bench/out/boot/\(o.arch)"
  makeDirectory(logs)
  let croiRevision = capture(["git", "-C", "../croi", "describe", "--always", "--dirty"]).map(trimmed) ?? "unknown"

  // croi, as checked out: a failure here is croi's, and said so.
  let croi = "build/croi/\(o.arch)"
  let root = FileManager.default.currentDirectoryPath
  if !FileManager.default.fileExists(atPath: "\(croi)/build.ninja") {
    let configure = ["cmake", "-S", "../croi", "-B", croi, "-G", "Ninja",
                     "-DCMAKE_TOOLCHAIN_FILE=\(root)/../croi/cmake/toolchain.cmake", "-DCROI_ARCH=\(o.arch)",
                     "-DCMAKE_BUILD_TYPE=RelWithDebInfo"]
    guard run(configure, log: "\(logs)/croi.log").ok else {
      complain("boot: croi (../croi at \(croiRevision)) didn't configure: see \(logs)/croi.log")
      return false
    }
  }
  // croi is worked on beside us: a file edited mid-build fails it once
  // ("modified during the build"), and a second build settles it.
  let kept = o.keepCroi && FileManager.default.fileExists(atPath: "\(croi)/kernel/kernel.elf")
  var built = kept || run(["ninja", "-C", croi, "loader-efi", "kernel"], log: "\(logs)/croi.log").ok
  if !built { built = run(["ninja", "-C", croi, "loader-efi", "kernel"], log: "\(logs)/croi.log").ok }
  if kept { say("td boot: croi as last built in \(croi) (--keep-croi)") }
  guard built else {
    complain("boot: croi (../croi at \(croiRevision)) didn't build: see \(logs)/croi.log")
    return false
  }

  // Ours.
  let native = "build/native-\(o.arch)"
  if !FileManager.default.fileExists(atPath: "\(native)/build.ninja") {
    guard run(["cmake", "--preset", "native-\(o.arch)"], log: "\(logs)/native.log").ok else {
      complain("boot: the native build didn't configure: see \(logs)/native.log")
      return false
    }
  }
  guard run(["cmake", "--build", "--preset", "native-\(o.arch)"], log: "\(logs)/native.log").ok else {
    complain("boot: the native build failed: see \(logs)/native.log")
    return false
  }

  // bootfs: every program the native build made.
  var files: [(name: String, data: [UInt8])] = []
  let programs = ((try? FileManager.default.contentsOfDirectory(atPath: "\(native)/bin")) ?? []).sorted()
  for p in programs {
    guard let data = try? Data(contentsOf: URL(filePath: "\(native)/bin/\(p)")) else { fail("can't read \(native)/bin/\(p)") }
    files.append(("bin/\(p)", Array(data)))
  }
  guard files.contains(where: { $0.name == o.next }) else { fail("boot: no \(o.next) in \(native)/bin") }
  // The launcher's manifests.
  if let dir = o.manifests {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".manifest") }
    guard !names.isEmpty else { fail("boot: no manifests in \(dir)") }
    for m in names.sorted() {
      guard let data = try? Data(contentsOf: URL(filePath: "\(dir)/\(m)")) else { fail("can't read \(dir)/\(m)") }
      files.append(("etc/manifests/\(m)", Array(data)))
    }
  }
  let image: [UInt8]
  do { image = try Bootfs.image(files) } catch { fail("boot: bootfs: \(error)") }

  let cmdline = (["userboot.next=\(o.next)"] + o.cmdline).joined(separator: " ")

  // The EFI system partition.
  let work = "build/boot/\(o.arch)"
  let esp = "\(work)/esp"
  removeTree(esp)
  makeDirectory("\(esp)/EFI/BOOT")
  makeDirectory("\(esp)/croi")
  let efiName = ["amd64": "BOOTX64.EFI", "arm64": "BOOTAA64.EFI", "rv64": "BOOTRISCV64.EFI"][o.arch]!
  do {
    try FileManager.default.copyItem(atPath: "\(croi)/boot/loader.efi", toPath: "\(esp)/EFI/BOOT/\(efiName)")
    try FileManager.default.copyItem(atPath: "\(croi)/kernel/kernel.elf", toPath: "\(esp)/croi/kernel.elf")
    try Data(image).write(to: URL(filePath: "\(esp)/croi/bootfs.img"))
    try Data("\(cmdline)\n".utf8).write(to: URL(filePath: "\(esp)/croi/cmdline"))
  } catch {
    fail("boot: laying out \(esp): \(error)")
  }

  guard var qemu = qemuCommand(o.arch, esp: esp, work: work) else { return false }
  qemu += o.qemuArgs
  say("td boot: croi \(croiRevision), \(files.count) file(s) in bootfs (\(image.count / 1024) KiB), \(cmdline)")
  if !o.test {
    return run(qemu + ["-nographic"], log: nil).ok
  }
  return bootTest(qemu + ["-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot"],
                  options: o, console: "\(logs)/console.log", croiRevision: croiRevision)
}

/// QEMU for `arch` with edk2's firmware, as croi's tools/qemu.sh runs it;
/// the firmware's variable stores are copied into `work` on first use.
func qemuCommand(_ arch: String, esp: String, work: String) -> [String]? {
  let edk2 = "/usr/share/edk2"
  func vars(_ template: String, _ name: String, size: Int? = nil) -> String {
    let path = "\(work)/\(name)"
    if !FileManager.default.fileExists(atPath: path) {
      try? FileManager.default.copyItem(atPath: template, toPath: path)
      if let size { truncate(path, off_t(size)) }
    }
    return path
  }
  var q: [String]
  switch arch {
  case "amd64":
    q = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "max",
         "-drive", "if=pflash,format=raw,readonly=on,file=\(edk2)/ovmf/OVMF_CODE.fd",
         "-drive", "if=pflash,format=raw,file=\(vars("\(edk2)/ovmf/OVMF_VARS.fd", "amd64-vars.fd"))"]
    if access("/dev/kvm", R_OK | W_OK) == 0 { q += ["-accel", "kvm"] }
  case "arm64":
    q = ["qemu-system-aarch64", "-machine", "virt,acpi=on,iommu=smmuv3,gic-version=3", "-cpu", "max", "-device", "ramfb",
         "-drive", "if=pflash,format=raw,readonly=on,file=\(edk2)/aarch64/QEMU_EFI-pflash.raw",
         "-drive", "if=pflash,format=raw,file=\(vars("\(edk2)/aarch64/vars-template-pflash.raw", "arm64-vars.raw"))"]
  default:
    let code = "\(work)/rv64-code.fd"
    if !FileManager.default.fileExists(atPath: code) {
      try? FileManager.default.copyItem(atPath: "\(edk2)/riscv/RISCV_VIRT_CODE.fd", toPath: code)
      truncate(code, 32 << 20)
    }
    q = ["qemu-system-riscv64", "-machine", "virt,acpi=on", "-cpu", "max", "-device", "ramfb",
         "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)",
         "-drive", "if=pflash,format=raw,unit=1,file=\(vars("\(edk2)/riscv/RISCV_VIRT_VARS.fd", "rv64-vars.fd", size: 32 << 20))"]
  }
  guard tool(q[0]) != nil else {
    complain("boot: \(q[0]) isn't installed")
    return nil
  }
  return q + ["-m", "512M", "-smp", "4", "-net", "none",
              "-drive", "if=none,format=raw,file=fat:rw:\(esp),id=esp", "-device", "virtio-blk-pci,drive=esp"]
}

/// Runs `qemu` headless until userboot reports how the program it started
/// exited, croi panics, or the time runs out. The console goes to
/// `console`; the end of it is shown when the boot fails.
func bootTest(_ qemu: [String], options o: BootOptions, console: String, croiRevision: String) -> Bool {
  var fds: [Int32] = [0, 0]
  guard pipe(&fds) == 0 else { fail("pipe: \(errno)") }
  var actions = posix_spawn_file_actions_t()
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
  posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
  posix_spawn_file_actions_addclose(&actions, fds[0])
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  var argv: [UnsafeMutablePointer<CChar>?] = qemu.map { strdup($0) } + [nil]
  defer { for p in argv { free(p) } }
  var pid = pid_t()
  let start = now()
  guard posix_spawnp(&pid, qemu[0], &actions, nil, &argv, environ) == 0 else {
    complain("boot: couldn't start \(qemu[0])")
    return false
  }
  close(fds[1])
  defer {
    kill(pid, SIGTERM)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    close(fds[0])
  }

  let done = "userboot: \(o.next) exited with "
  var lines: [String] = []
  var pending: [UInt8] = []
  var verdict: (ok: Bool, why: String)?
  var buffer = [UInt8](repeating: 0, count: 4096)
  while verdict == nil {
    let left = o.timeout - (now() - start)
    if left <= 0 {
      verdict = (false, "no report from userboot in \(Int(o.timeout)) s")
      break
    }
    var p = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
    let ready = poll(&p, 1, Int32(min(left, 1) * 1000))
    if ready < 0 && errno == EINTR { continue }
    if ready <= 0 { continue }
    let n = read(fds[0], &buffer, buffer.count)
    if n <= 0 {
      verdict = (false, "QEMU exited before userboot reported")
      break
    }
    for b in buffer[0..<n] {
      if b == UInt8(ascii: "\n") {
        let line = String(decoding: pending.filter { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        lines.append(line)
        if line.contains(done) {
          let code = line.split(separator: " ").last.map(String.init) ?? ""
          verdict = code == "0" ? (true, "") : (false, "\(o.next) exited with \(code)")
        } else if line.contains("PANIC") || line.contains("panic:") {
          verdict = (false, "croi panicked (../croi at \(croiRevision))")
        }
      } else {
        pending.append(b)
      }
    }
  }
  // Traces the guest wrote out (lib/trace/session) go beside the console.
  let traceLines = lines.filter { $0.contains("td-trace ") }
  try? Data(lines.filter { !$0.contains("td-trace ") }.joined(separator: "\n").utf8)
    .write(to: URL(filePath: console))
  if !traceLines.isEmpty {
    let logs = String(console[..<(console.lastIndex(of: "/") ?? console.startIndex)])
    try? Data(traceLines.joined(separator: "\n").utf8).write(to: URL(filePath: "\(logs)/trace.log"))
    let dir = "\(logs)/trace"
    switch reassembleTraces(traceLines, into: dir) {
    case .success(let files): say("td boot: \(files) trace file(s) in \(dir) (td trace summary \(dir))")
    case .failure(let why):
      if verdict!.ok { verdict = (false, "the guest's trace is damaged: \(why.description)") }
    }
  }
  let seconds = now() - start
  if verdict!.ok {
    say("td boot: \(o.next) exited with 0 (\(format(seconds)) s from power on; console in \(console))")
    return true
  }
  complain("boot: FAILED: \(verdict!.why); the console's end (all of it in \(console)):")
  for line in lines.suffix(30) { complain("  \(line)") }
  return false
}

struct TraceDamage: Error, CustomStringConvertible {
  let description: String
}

/// The files `td-trace NAME OFFSET BASE64` lines carry (or `td-trace NAME
/// OFFSET zero COUNT`), each ended by `td-trace NAME end SIZE`
/// (lib/trace/session's export), written to `dir` as NAME.trace. A piece
/// the console dropped is reported (a piece sent twice is taken once).
/// The number of files.
func reassembleTraces(_ lines: [String], into dir: String) -> Result<Int, TraceDamage> {
  removeTree(dir)
  makeDirectory(dir)
  var pieces: [String: [Int: [UInt8]]] = [:]
  var sizes: [String: Int] = [:]
  for line in lines {
    let all = line.split(separator: " ").map(String.init)
    guard let at = all.firstIndex(of: "td-trace") else { continue }
    let words = Array(all[(at + 1)...])
    guard words.count >= 3 else { continue }  // a line the console cut short: the other copy has it
    let name = words[0]
    if words[1] == "end" {
      if let n = Int(words[2]) { sizes[name] = n }
      continue
    }
    guard let offset = Int(words[1]) else { continue }
    if words.count == 4, words[2] == "zero", let n = Int(words[3]) {
      pieces[name, default: [:]][offset] = [UInt8](repeating: 0, count: n)
    } else if words.count == 3, let data = Data(base64Encoded: words[2]) {
      pieces[name, default: [:]][offset] = [UInt8](data)
    }
  }
  for (name, size) in sizes.sorted(by: { $0.key < $1.key }) {
    var bytes: [UInt8] = []
    while bytes.count < size {
      guard let piece = pieces[name]?[bytes.count], !piece.isEmpty else {
        return .failure(TraceDamage(description: "\(name): the piece at \(bytes.count) is missing (the console dropped it)"))
      }
      bytes += piece
    }
    guard bytes.count == size else { return .failure(TraceDamage(description: "\(name) is \(bytes.count) bytes, not \(size)")) }
    do {
      _ = try TraceFile(bytes: bytes)
    } catch {
      return .failure(TraceDamage(description: "\(name) doesn't read as a trace: \(error)"))
    }
    guard (try? Data(bytes).write(to: URL(filePath: "\(dir)/\(name).trace"))) != nil else {
      return .failure(TraceDamage(description: "can't write \(dir)/\(name).trace"))
    }
  }
  if let lost = pieces.keys.first(where: { sizes[$0] == nil }) {
    return .failure(TraceDamage(description: "\(lost) has no end"))
  }
  return .success(sizes.count)
}
