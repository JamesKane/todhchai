// SPDX-License-Identifier: BSD-3-Clause

// What a native launcher is started with, read from userboot's handles
// and bootfs's directory (not the whole image): the root job, every
// `bin/NAME` as a program a manifest may name, and every
// `etc/manifests/*.manifest`. Shared by bin/launcher and the launcher-driven
// tests (tests/native/N0Exit.swift).

import Bootfs
import LibSys
import Sys

struct Boot: ~Copyable {
  let job: Handle
  /// Open for as long as the launcher runs: programs load from it.
  let bootfs: Handle
  var programs: [(name: String, entry: ProgramEntry)] = []
  var manifests: [(path: String, text: String)] = []

  static func fail(_ what: String) -> Never {
    print("\(Arguments.strings.first ?? "launcher"): \(what)")
    exit(1)
  }

  init() {
    guard let jobRaw = StartupHandles.take(ProcessArgs.info(ProcessArgs.jobDefault)),
      let bootfsRaw = StartupHandles.take(ProcessArgs.info(ProcessArgs.vmoBootfs))
    else { Self.fail("started without a job or bootfs") }
    job = Handle(raw: jobRaw)
    bootfs = Handle(raw: bootfsRaw)

    let entries: [Bootfs.Entry]
    do throws(Status) {
      let size = try VMO.size(bootfs)
      let header = try VMO.read(bootfs, offset: 0, count: Bootfs.headerSize)
      guard let end = try? Bootfs.directoryEnd(header: header), end <= size else { Self.fail("bootfs is malformed") }
      let directory = try VMO.read(bootfs, offset: 0, count: end)
      guard let all = try? Bootfs.entries(directory: directory, imageSize: size) else {
        Self.fail("bootfs is malformed")
      }
      entries = all
    } catch {
      Self.fail("can't read bootfs: \(error)")
    }
    for e in entries {
      if let name = e.name.dropping("bin/") {
        programs.append((name, ProgramEntry(image: bootfs.raw, offset: e.offset, length: e.length, name: e.name)))
      } else if e.name.dropping("etc/manifests/") != nil,
        e.name.utf8.reversed().starts(with: ".manifest".utf8.reversed())
      {
        do throws(Status) {
          let bytes = try VMO.read(bootfs, offset: e.offset, count: e.length)
          manifests.append((e.name, String(decoding: bytes, as: UTF8.self)))
        } catch {
          Self.fail("can't read \(e.name): \(error)")
        }
      }
    }
  }
}

extension String {
  /// The rest, if it starts with `prefix` (compared as bytes).
  func dropping(_ prefix: String) -> String? {
    guard utf8.starts(with: prefix.utf8) else { return nil }
    return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
  }
}
