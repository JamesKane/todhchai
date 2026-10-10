// SPDX-License-Identifier: BSD-3-Clause

// N0's exit (docs/milestones/N0.md), M3's exit hosted: the launcher starts
// the block service, the fs service and a client, each in its own hosted
// process with only the namespace its manifest gives it. The client mounts
// a Taisce volume through /svc/fs, writes files with attributes, and sees a
// live query's update; a service's tree reads like files; a manifest that
// names a missing service stops the launch with its line; and a service
// that dies is restarted by its policy, its client reconnecting. The
// programs and manifests are the hosted boot's (lib/hosted, boot/manifests),
// over an image of the test's own.

import Glibc
import HostedPrograms
import IPC
import Launch
import Node
import Testing

/// The hosted boot's manifests, with the block image put at `image`.
func bootManifests(image: String) throws -> [(path: String, text: String)] {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // tests/milestones/N0ExitTests.swift
  let dir = parts.joined(separator: "/") + "/boot/manifests"
  return try ["block", "fs", "catalog"].map { name in
    let path = "\(dir)/\(name).manifest"
    guard let f = fopen(path, "r") else { throw LaunchError("can't read \(path)") }
    defer { fclose(f) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while case let n = fread(&buffer, 1, buffer.count, f), n > 0 { bytes += buffer[..<n] }
    let text = String(decoding: bytes, as: UTF8.self).replacing(".build/hosted/block.img", with: image)
    return (path: path, text: text)
  }
}

func read(_ l: Launcher, _ path: String) throws -> String {
  let names = path.split(separator: "/", maxSplits: 1).map(String.init)
  var root = try l.open(names[0])
  var leaf = try root.open(names[1])
  return try leaf.readText()
}

@Test func n0Exit() throws {
  let dir = ".build/n0-exit-\(getpid())"
  let image = "\(dir)/block.img"
  defer {
    unlink(image)
    rmdir(dir)
  }
  let manifests = try bootManifests(image: image)
  let l = try Launcher(programs: hostedPrograms, rootJob: try Job.root())
  defer { l.stop() }
  try l.start(manifests)
  #expect(l.status == "block running restarts 0\nfs running restarts 0\ncatalog running restarts 0\n")

  // The client wrote songs with attributes into the volume it mounted
  // through /svc/fs, and the live query saw the one that matched arrive.
  // Its namespace holds what its manifest grants, and what it mounted:
  // /svc holds fs and not block.
  let catalog = try read(l, "catalog/status")
  #expect(catalog.hasPrefix("namespace /data /svc\nsvc fs\n"), "\(catalog)")
  #expect(catalog.contains("live: added /music/Anam.flac\n"))
  #expect(catalog.contains("Anam.flac 1990\n") && catalog.contains("reconnects 0\n"))

  // A service's tree reads like files: cat /svc/fs/status, and the songs.
  #expect(try read(l, "fs/status").hasPrefix("volume main\ndevice /svc/block/device\n"))
  #expect(try read(l, "fs/volume/music/Dulaman.flac") == "Dulaman.flac\n")
  #expect(try read(l, "block/status").contains("sessions 1\n"))

  // The fs service dies; its policy restarts it, and the client sees its
  // channel close and mounts the volume again, which still holds the songs.
  try l.kill("fs")
  var restarted = false
  for _ in 0..<300 where !restarted {
    sleep(until: Clock.monotonic() + 10_000_000)
    restarted = l.status.contains("fs running restarts 1\n")
  }
  #expect(restarted, "\(l.status)")
  let after = try read(l, "catalog/status")
  #expect(after.contains("Anam.flac 1990\n") && after.contains("reconnects 1\n"), "\(after)")
}

@Test func aManifestNamingAMissingServiceStopsTheLaunch() throws {
  let l = try Launcher(programs: hostedPrograms, rootJob: try Job.root())
  defer { l.stop() }
  var message = "started"
  do {
    try l.start([(path: "catalog.manifest", text: "service catalog\nprogram catalog\nuse fs\nexport\n")])
  } catch {
    message = "\(error)"
  }
  #expect(message == "catalog.manifest:3: no service 'fs'")
}
