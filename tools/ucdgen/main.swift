// SPDX-License-Identifier: BSD-3-Clause

// ucdgen DATA-DIR OUTPUT: writes TDUnicode's tables from the UCD files in
// DATA-DIR (data/unicode).

import FoundationEssentials
import Glibc
import UCDGen

let args = CommandLine.arguments
guard args.count == 3 else {
  print("usage: ucdgen data/unicode lib/unicode/generated/Tables.swift")
  exit(2)
}
func read(_ name: String) -> String {
  guard let s = try? String(contentsOfFile: "\(args[1])/\(name)", encoding: .utf8) else {
    print("ucdgen: can't read \(args[1])/\(name)")
    exit(1)
  }
  return s
}
let ucd = UCD(unicodeData: read("UnicodeData.txt"), compositionExclusions: read("CompositionExclusions.txt"),
              caseFolding: read("CaseFolding.txt"))
do {
  try ucd.swift().write(toFile: args[2], atomically: true, encoding: .utf8)
} catch {
  print("ucdgen: can't write \(args[2]): \(error)")
  exit(1)
}
print("ucdgen: Unicode \(ucd.version): \(ucd.decomposition.count) decompositions, \(ucd.compositions.count) composites, \(ucd.folding.count) foldings")
