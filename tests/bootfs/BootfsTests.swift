// SPDX-License-Identifier: BSD-3-Clause

import Bootfs
import FoundationEssentials
import Glibc
import Testing

func word(_ image: [UInt8], _ at: Int) -> UInt32 {
  UInt32(image[at]) | UInt32(image[at + 1]) << 8 | UInt32(image[at + 2]) << 16 | UInt32(image[at + 3]) << 24
}

func setWord(_ image: inout [UInt8], _ at: Int, _ v: UInt32) {
  for i in 0..<4 { image[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
}

let files: [(name: String, data: [UInt8])] = [
  ("bin/launcher", Array(0..<200).map { UInt8($0) }),
  ("etc/empty", []),
  ("data/page", [UInt8](repeating: 0xAB, count: 4096)),
  ("x", [1, 2, 3]),
]

@Test func roundTrips() throws {
  let image = try Bootfs.image(files)
  let entries = try Bootfs.entries(image)
  #expect(entries.map(\.name) == files.map(\.name))
  for (entry, file) in zip(entries, files) {
    #expect(entry.offset % Bootfs.pageSize == 0)
    #expect(entry.length == file.data.count)
    #expect(Array(image[entry.offset..<(entry.offset + entry.length)]) == file.data)
  }
  #expect(try Bootfs.find("data/page", in: image)?.length == 4096)
  #expect(try Bootfs.find("data", in: image) == nil)
}

@Test func layoutIsZirconsFormat() throws {
  let image = try Bootfs.image(files)
  #expect(image.count % Bootfs.pageSize == 0)
  #expect(word(image, 0) == Bootfs.magic)
  // Each entry: three words, the name and its NUL, padded to 4 bytes.
  let directory = files.reduce(0) { $0 + (12 + $1.name.utf8.count + 1 + 3) / 4 * 4 }
  #expect(word(image, 4) == UInt32(directory))
  #expect(word(image, 8) == 0 && word(image, 12) == 0)
  // The first entry's name length counts the NUL; its data starts on the
  // first page after the directory.
  #expect(word(image, 16) == UInt32("bin/launcher".utf8.count + 1))
  #expect(word(image, 24) == 4096)
  #expect(image[16 + 12 + 12] == 0)
  // Files follow one another, each on its own pages; an empty file takes none.
  let e = try Bootfs.entries(image)
  #expect(e[1].offset == 8192 && e[2].offset == 8192 && e[3].offset == 12288)
}

@Test func refusesBadNames() {
  #expect(throws: Bootfs.Error.badName("")) { try Bootfs.image([("", [])]) }
  #expect(throws: Bootfs.Error.badName("/bin/x")) { try Bootfs.image([("/bin/x", [])]) }
  let long = String(repeating: "a", count: 256)
  #expect(throws: Bootfs.Error.badName(long)) { try Bootfs.image([(long, [])]) }
  #expect(throws: Bootfs.Error.duplicate("a")) { try Bootfs.image([("a", [1]), ("a", [2])]) }
  #expect((try? Bootfs.image([(String(repeating: "a", count: 255), [])])) != nil)
}

@Test func refusesDamagedImages() throws {
  let good = try Bootfs.image(files)
  #expect(throws: Bootfs.Error.badHeader) { try Bootfs.entries([]) }
  var bad = good
  setWord(&bad, 0, 0x1234_5678)
  #expect(throws: Bootfs.Error.badHeader) { try Bootfs.entries(bad) }
  bad = good
  setWord(&bad, 4, UInt32(good.count))  // a directory past the image's end
  #expect(throws: Bootfs.Error.badHeader) { try Bootfs.entries(bad) }
  bad = good
  setWord(&bad, 24, 4097)  // data not on a page
  #expect(throws: Bootfs.Error.badEntry(at: 16)) { try Bootfs.entries(bad) }
  bad = good
  setWord(&bad, 20, UInt32(good.count))  // data past the image's end
  #expect(throws: Bootfs.Error.badEntry(at: 16)) { try Bootfs.entries(bad) }
  bad = good
  setWord(&bad, 16, 300)  // a name longer than the limit
  #expect(throws: Bootfs.Error.badEntry(at: 16)) { try Bootfs.entries(bad) }
  bad = good
  bad[16 + 12 + 12] = UInt8(ascii: "!")  // a name without its NUL
  #expect(throws: Bootfs.Error.badEntry(at: 16)) { try Bootfs.entries(bad) }
}

/// croi's userboot is the reader that matters: our images are byte for
/// byte what croi's own tool writes, when croi is beside us.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "../croi/tools/mkbootfs.py")))
func matchesCroisWriter() throws {
  let dir = "/tmp/td-bootfs-\(getpid())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  var args = ["python3", "-I", "../croi/tools/mkbootfs.py", "\(dir)/croi.img"]
  for (i, f) in files.enumerated() {
    let path = "\(dir)/\(i)"
    try Data(f.data).write(to: URL(filePath: path))
    args.append("\(f.name)=\(path)")
  }
  var pid = pid_t()
  var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
  defer { for p in argv { free(p) } }
  #expect(posix_spawnp(&pid, "python3", nil, nil, &argv, environ) == 0)
  var status: Int32 = 0
  waitpid(pid, &status, 0)
  #expect(status == 0)
  let theirs = Array(try Data(contentsOf: URL(filePath: "\(dir)/croi.img")))
  #expect(try Bootfs.image(files) == theirs)
}
