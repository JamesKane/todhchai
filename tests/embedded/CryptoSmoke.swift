// SPDX-License-Identifier: BSD-3-Clause

// TDCrypto built as Embedded Swift on the host: BLAKE3 against two of the
// official vectors (tests/crypto runs all of them).

import TDCrypto

@main struct CryptoSmoke {
  static func main() {
    // The empty input, and 1,025 bytes of the vectors' 0...250 pattern (two chunks).
    let empty: [UInt8] = [0xaf, 0x13, 0x49, 0xb9, 0xf5, 0xf9, 0xa1, 0xa6, 0xa0, 0x40, 0x4d, 0xea, 0x36, 0xdc, 0xc9, 0x49]
    check(BLAKE3.hash([], count: 16) == empty, "blake3, empty")
    let input = (0..<1025).map { UInt8($0 % 251) }
    let expected: [UInt8] = [0xd0, 0x02, 0x78, 0xae, 0x47, 0xeb, 0x27, 0xb3, 0x4f, 0xae, 0xcf, 0x67, 0xb4, 0xfe, 0x26, 0x3f]
    check(BLAKE3.hash(input, count: 16) == expected, "blake3, two chunks")
    print("embedded TDCrypto: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
