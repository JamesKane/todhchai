// SPDX-License-Identifier: BSD-3-Clause

// vkgen: vk.xml → the C header lib/vulkan/c/include/td_vulkan.h.
//
//   vkgen OUTPUT.h COMMANDS.swift vk.xml

import FoundationEssentials
import Glibc
import VulkanGen

func fail(_ message: String) -> Never {
  let line = Array("vkgen: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else { fail("usage: vkgen OUTPUT.h COMMANDS.swift vk.xml") }
guard let text = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("can't read \(args[2])") }
do {
  let registry = try VulkanRegistry(text)
  let generator = try CHeaderGenerator(registry, loinnirSelection)
  try generator.generate(source: "vk.xml").write(toFile: args[0], atomically: true, encoding: .utf8)
  try generator.swiftCommands(source: "vk.xml").write(toFile: args[1], atomically: true, encoding: .utf8)
} catch {
  fail("\(error)")
}
