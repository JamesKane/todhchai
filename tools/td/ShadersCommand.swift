// SPDX-License-Identifier: BSD-3-Clause

// td shaders: compiles GLSL to SPIR-V with glslang (a toolchain,
// principle 29; M1 decision 2). Every .vert, .frag and .comp under lib/,
// tests/ and examples/ gets a .spv beside it, which is committed, so a
// build needs no shader compiler. --check recompiles and fails if any
// committed .spv is missing or stale.

import FoundationEssentials
import Glibc

func shaderSources() -> [String] {
  let roots = ["lib", "tests", "examples"].filter { FileManager.default.fileExists(atPath: $0) }
  let found = capture(["find"] + roots + ["-name", "*.vert", "-o", "-name", "*.frag", "-o", "-name", "*.comp"]) ?? ""
  return found.split(separator: "\n").map(String.init).sorted()
}

func shaders(check: Bool) -> Bool {
  var ok = true
  let scratch = "/tmp/td-shaders-\(getpid())"
  makeDirectory(scratch)
  defer { removeTree(scratch) }
  for source in shaderSources() {
    let target = source + ".spv"
    let output = check ? "\(scratch)/out.spv" : target
    let log = "\(scratch)/log"
    let r = run(["glslangValidator", "-V", "--target-env", "vulkan1.3", "-o", output, source], log: log)
    guard r.ok else {
      complain("\(source) doesn't compile:\n" + ((try? String(contentsOfFile: log, encoding: .utf8)) ?? ""))
      ok = false
      continue
    }
    if check {
      let fresh = FileManager.default.contents(atPath: output)
      let committed = FileManager.default.contents(atPath: target)
      if fresh != committed {
        complain("\(target) is \(committed == nil ? "missing" : "stale"): run td shaders")
        ok = false
      }
    } else {
      say("  \(target)")
    }
  }
  return ok
}
