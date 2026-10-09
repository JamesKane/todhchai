// SPDX-License-Identifier: BSD-3-Clause

// td acpi: the corpus of firmware tables the AML interpreter is tested on
// (docs/milestones/A0.md). It stays out of the tree, in .cache/acpi (one
// directory a machine, each table a file named by signature): firmware
// tables are vendor binaries, and QEMU's are GPL-licensed fixtures.
//
//   td acpi import [NAME]
//       This machine's tables, from /sys/firmware/acpi/tables (root only:
//       run it with sudo, and the files are given back to you), and Linux's
//       view of its namespace from /sys/bus/acpi/devices, the oracle the
//       interpreter's enumeration is checked against. NAME: the host name.
//   td acpi fetch-qemu
//       QEMU's tables for x86 (q35, pc, microvm), arm64 virt and riscv64
//       virt: its regression fixtures, at the pinned release below.
//   td acpi list
//       What the corpus holds.

import FoundationEssentials
import Glibc
import TDACPI

let acpiCorpus = ".cache/acpi"

/// QEMU's fixtures: tests/data/acpi at v11.1.2.
let qemuRelease = "v11.1.2"
let qemuCommit = "4fc49f46dc95d4a27de2509e7fceb2931e91faeb"
let qemuMachines = [("x86/q35", "qemu-x86-q35"), ("x86/pc", "qemu-x86-pc"), ("x86/microvm", "qemu-x86-microvm"),
                    ("aarch64/virt", "qemu-aarch64-virt"), ("riscv64/virt", "qemu-riscv64-virt")]

func acpiCommand(_ args: [String]) -> Bool {
  switch args.first {
  case "import": return acpiImport(name: args.count > 1 ? args[1] : hostName())
  case "fetch-qemu": return acpiFetchQEMU()
  case "list": return acpiList()
  default:
    complain("usage: td acpi import [NAME] | fetch-qemu | list")
    return false
  }
}

func hostName() -> String {
  var name = [CChar](repeating: 0, count: 256)
  gethostname(&name, 255)
  return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func readFile(_ path: String) -> [UInt8]? {
  FileManager.default.contents(atPath: path).map { [UInt8]($0) }
}

func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
  FileManager.default.createFile(atPath: path, contents: Data(bytes))
}

/// Under sudo, gives what we wrote back to the user who asked.
func giveBack(_ path: String) {
  guard let uid = getenv("SUDO_UID").flatMap({ UInt32(String(cString: $0)) }),
    let gid = getenv("SUDO_GID").flatMap({ UInt32(String(cString: $0)) })
  else { return }
  _ = chown(path, uid, gid)
}

func acpiImport(name: String) -> Bool {
  let source = "/sys/firmware/acpi/tables"
  let target = "\(acpiCorpus)/\(name)"
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: source) else {
    complain("can't list \(source)")
    return false
  }
  var tables: [(String, [UInt8])] = []
  for table in names.sorted() {
    var st = stat()
    guard stat("\(source)/\(table)", &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }  // not data/, dynamic/
    guard let bytes = readFile("\(source)/\(table)") else {
      complain("can't read \(source)/\(table): the tables need root. Run: sudo .build/debug/td acpi import \(name)")
      return false
    }
    tables.append((table, bytes))
  }
  makeDirectory(acpiCorpus)
  makeDirectory(target)
  giveBack(".cache")
  giveBack(acpiCorpus)
  giveBack(target)
  for (table, bytes) in tables {
    guard writeFile("\(target)/\(table)", bytes) else { fail("can't write \(target)/\(table)") }
    giveBack("\(target)/\(table)")
  }
  // The oracle: Linux's (ACPICA's) view of the same namespace.
  var rows = ["# path\thid\tuid\tadr\tstatus\tmodalias"]
  let devices = "/sys/bus/acpi/devices"
  for device in ((try? FileManager.default.contentsOfDirectory(atPath: devices)) ?? []).sorted() {
    func field(_ f: String) -> String {
      readFile("\(devices)/\(device)/\(f)").map { trimmed(String(decoding: $0, as: UTF8.self)) } ?? ""
    }
    let path = field("path")
    guard !path.isEmpty else { continue }
    rows.append([path, field("hid"), field("uid"), field("adr"), field("status"), field("modalias")].joined(separator: "\t"))
  }
  let oracle = "\(target)/linux-devices.tsv"
  guard writeFile(oracle, Array((rows.joined(separator: "\n") + "\n").utf8)) else { fail("can't write \(oracle)") }
  giveBack(oracle)
  let provenance = """
    This machine's ACPI tables, from /sys/firmware/acpi/tables, and Linux's
    view of its namespace (linux-devices.tsv, from /sys/bus/acpi/devices).
    Firmware: vendor binaries, kept out of the tree. Imported by td acpi import.

    """
  _ = writeFile("\(target)/PROVENANCE", Array(provenance.utf8))
  giveBack("\(target)/PROVENANCE")
  say("td acpi: \(tables.count) tables and \(rows.count - 1) devices in \(target)")
  return true
}

func acpiFetchQEMU() -> Bool {
  let checkout = "\(acpiCorpus)/qemu-src"
  removeTree(checkout)
  makeDirectory(acpiCorpus)
  let url = "https://gitlab.com/qemu-project/qemu.git"
  guard run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", qemuRelease, url, checkout],
            log: nil).ok,
    run(["git", "-C", checkout, "sparse-checkout", "set", "tests/data/acpi"], log: nil).ok
  else {
    complain("fetching QEMU \(qemuRelease) failed")
    return false
  }
  guard let head = capture(["git", "-C", checkout, "rev-parse", "HEAD"]), trimmed(head) == qemuCommit else {
    complain("QEMU \(qemuRelease) isn't the commit pinned (\(qemuCommit)): check the tag before trusting it")
    return false
  }
  for (from, to) in qemuMachines {
    let target = "\(acpiCorpus)/\(to)"
    removeTree(target)
    makeDirectory(target)
    for file in ((try? FileManager.default.contentsOfDirectory(atPath: "\(checkout)/tests/data/acpi/\(from)")) ?? []) {
      guard let bytes = readFile("\(checkout)/tests/data/acpi/\(from)/\(file)"), writeFile("\(target)/\(file)", bytes)
      else { fail("can't copy \(from)/\(file)") }
    }
    let provenance = """
      QEMU's expected ACPI tables for \(from), from tests/data/acpi in QEMU
      \(qemuRelease) (commit \(qemuCommit)), https://gitlab.com/qemu-project/qemu.
      Files without a suffix are the default machine's; DSDT.x and the like
      are the same machine with other options. QEMU is GPL-2.0: kept out of
      the tree. Fetched by td acpi fetch-qemu.

      """
    _ = writeFile("\(target)/PROVENANCE", Array(provenance.utf8))
  }
  removeTree(checkout)
  say("td acpi: QEMU \(qemuRelease)'s tables for \(qemuMachines.count) machines in \(acpiCorpus)")
  return true
}

func acpiList() -> Bool {
  guard let machines = try? FileManager.default.contentsOfDirectory(atPath: acpiCorpus), !machines.isEmpty else {
    say("td acpi: the corpus is empty; td acpi import, td acpi fetch-qemu")
    return true
  }
  for machine in machines.sorted() {
    let dir = "\(acpiCorpus)/\(machine)"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    var aml = 0, amlBytes = 0, others = 0
    for f in files where f != "PROVENANCE" && !f.hasSuffix(".tsv") {
      guard let bytes = readFile("\(dir)/\(f)"), let t = try? Table(bytes) else { continue }
      if t.signature == .dsdt || t.signature == .ssdt {
        aml += 1
        amlBytes += t.length
      } else {
        others += 1
      }
    }
    let oracle = FileManager.default.fileExists(atPath: "\(dir)/linux-devices.tsv") ? ", Linux's device view" : ""
    say("\(machine): \(aml) DSDT/SSDTs (\(amlBytes / 1024) KiB of AML), \(others) other tables\(oracle)")
  }
  return true
}
