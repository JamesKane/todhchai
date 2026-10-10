// SPDX-License-Identifier: BSD-3-Clause

// td ci: everything a change must pass, in one command. Each step's output
// is in bench/out/ci/<step>.log.

import Bench
import FoundationEssentials

/// Protocol files, the directory holding their API baselines, and the
/// files of libraries they compose protocols from.
let protocols: [(file: String, baselines: String, with: [String])] = [
  ("tests/ipc/echo/Echo.swift", "tests/ipc/baselines", []),
  ("lib/node/Node.swift", "lib/node/idl", []),
  ("lib/node/Srv.swift", "lib/node/idl", []),
  ("lib/launch/Startup.swift", "lib/launch/idl", []),
  ("lib/block/Block.swift", "lib/block/idl", []),
  ("lib/fs/Fs.swift", "lib/fs/idl", ["lib/node/Node.swift"]),
]

/// idlc's C headers, which must compile cleanly.
let protocolHeaders = ["tests/ipc/c/generated/test_ipc.h", "lib/node/idl/node_ipc.h", "lib/node/idl/srv_ipc.h", "lib/launch/idl/launch_ipc.h",
                      "lib/block/idl/block_ipc.h", "lib/fs/idl/fs_ipc.h"]

func ci(bench benchOptions: BenchOptions?) -> Bool {
  let logs = "bench/out/ci"
  removeTree(logs)
  makeDirectory(logs)
  var steps: [(String, [[String]])] = [
    ("hosted-build", [["swift", "build"]]),
    ("hosted-tests", [["swift", "test"]]),
    ("embedded", [["cmake", "--workflow", "--preset", "embedded"]]),
    // Tier 0 for croi's three arches; amd64 boots (M3, decided).
    ("native-amd64", [["cmake", "--workflow", "--preset", "native-amd64"]]),
    ("native-arm64", [["cmake", "--workflow", "--preset", "native-arm64"]]),
    ("native-rv64", [["cmake", "--workflow", "--preset", "native-rv64"]]),
    ("boot-amd64", [[".build/debug/td", "boot", "--test", "--manifests", "tests/native/manifests",
                     "--cmdline", "launcher.until=launch-test"]]),
    ("sys-test-amd64", [[".build/debug/td", "boot", "--test", "--next", "bin/sys-test"]]),
    ("services-test-amd64", [[".build/debug/td", "boot", "--test", "--next", "bin/services-test"]]),
    ("shaders", [[".build/debug/td", "shaders", "--check"]]),
  ]
  steps.append(("c-abi", cABISteps(bin: "\(logs)/bin")))
  for p in protocols {
    steps.append(("baseline \(p.file)",
                  [["swift", "run", "idlc", "--baseline", p.baselines] + p.with.flatMap { ["--with", $0] } + [p.file]]))
  }
  steps.append(("hostboot", [["swift", "build", "--product", "hostboot"], [".build/debug/hostboot", "--check"]]))
  steps.append(("c-headers", protocolHeaders.map { h in
    ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsyntax-only", "-Ilib/sys/host/c/include",
     "-Ilib/ipc/c/include", "-include", h, "-x", "c", "/dev/null"]
  }))
  var passed = true
  for (name, commands) in steps {
    let log = "\(logs)/\(String(name.map { $0 == "/" || $0 == " " ? "_" : $0 })).log"
    var ok = true
    var seconds = 0.0
    for c in commands where ok {
      let r = run(c, log: log)
      ok = r.ok
      seconds += r.seconds
    }
    say("\(ok ? "ok  " : "FAIL") \(name) (\(format(seconds)) s)\(ok ? "" : ": see \(log)")")
    passed = passed && ok
  }
  if let benchOptions {
    passed = bench(benchOptions) && passed
  }
  say(passed ? "td ci: passed" : "td ci: FAILED")
  return passed
}

/// The C ABI from outside Swift: libtodhchai.so, then the minimal program
/// compiled in C, and in Zig and Odin where their compilers are installed
/// (a missing one is reported, not failed: toolchains, principle 29).
func cABISteps(bin: String) -> [[String]] {
  makeDirectory(bin)
  let lib = ".build/debug"
  let rpath = "\(FileManager.default.currentDirectoryPath)/\(lib)"
  var steps: [[String]] = [
    ["swift", "build", "--product", "todhchai"],
    ["cc", "-std=c11", "-Wall", "-Wextra", "-pedantic", "-Werror", "-Ilib/capi/c/include", "examples/minimal/minimal.c",
     "-L\(lib)", "-ltodhchai", "-Wl,-rpath,\(rpath)", "-o", "\(bin)/minimal-c"],
    ["c++", "-x", "c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-Ilib/capi/c/include", "-fsyntax-only",
     "lib/capi/c/include/todhchai/todhchai.h"],
  ]
  if let zig = tool("zig") {
    steps.append([zig, "build-exe", "--dep", "todhchai", "-Mroot=examples/minimal/minimal.zig",
                  "-Mtodhchai=lib/capi/zig/todhchai.zig", "-lc", "-L\(lib)", "-ltodhchai", "-rpath", rpath,
                  "-femit-bin=\(bin)/minimal-zig"])
  } else {
    say("     c-abi: zig isn't installed; the Zig bindings aren't compiled")
  }
  if let odin = tool("odin") ?? (FileManager.default.fileExists(atPath: "/opt/odin/odin") ? "/opt/odin/odin" : nil) {
    steps.append([odin, "build", "examples/minimal/minimal.odin", "-file", "-out:\(bin)/minimal-odin",
                  "-extra-linker-flags:-L\(rpath) -Wl,-rpath,\(rpath)"])
  } else {
    say("     c-abi: odin isn't installed; the Odin bindings aren't compiled")
  }
  return steps
}

/// A program on PATH, or nil.
func tool(_ name: String) -> String? {
  guard let path = capture(["sh", "-c", "command -v \(name)"]).map(trimmed), !path.isEmpty else { return nil }
  return path
}
