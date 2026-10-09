// SPDX-License-Identifier: BSD-3-Clause

// The corpus of real firmware tables (td acpi; docs/milestones/A0.md),
// out of the tree in .cache/acpi. Tests over it skip when it's absent.

import FoundationEssentials
import TDACPI

enum Corpus {
  /// .cache/acpi at the repository's root, found from this file.
  static let root: String = {
    var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    parts.removeLast(3)  // tests/acpi/Corpus.swift
    return parts.joined(separator: "/") + "/.cache/acpi"
  }()

  static var isPresent: Bool { !machines.isEmpty }

  /// Each machine's directory name.
  static var machines: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  /// A machine's files that hold tables: everything but PROVENANCE and the oracle.
  static func tableFiles(_ machine: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(machine)")) ?? [])
      .filter { $0 != "PROVENANCE" && !$0.hasSuffix(".tsv") }.sorted()
  }

  static func bytes(_ machine: String, _ file: String) -> [UInt8]? {
    FileManager.default.contents(atPath: "\(root)/\(machine)/\(file)").map { [UInt8]($0) }
  }
}
