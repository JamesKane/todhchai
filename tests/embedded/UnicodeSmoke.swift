// SPDX-License-Identifier: BSD-3-Clause

// TDUnicode built as Embedded Swift on the host: a few normalizations and
// foldings. tests/unicode runs the whole conformance test.

import TDUnicode

@main struct UnicodeSmoke {
  static func main() {
    check(Normalization.nfc([0x65, 0x301]) == [0xE9], "nfc")
    check(Normalization.nfd([0xE9]) == [0x65, 0x301], "nfd")
    check(Normalization.nfc([0x1100, 0x1161, 0x11A8]) == [0xAC01], "hangul")  // 각
    check(Normalization.nfd([0x1E0B, 0x323]) == [0x64, 0x323, 0x307], "canonical order")
    check(CaseFolding.fold([0xDF]) == [0x73, 0x73], "fold ß")
    check(UTF8Text.decode([0xED, 0xA0, 0x80]) == nil, "no surrogates")
    check(Text.caselessKey([0x43, 0x41, 0x46, 0x45, 0xCC, 0x81]) == [0x63, 0x61, 0x66, 0xC3, 0xA9], "caseless key")
    print("embedded TDUnicode: ok")
  }

  static func check(_ ok: Bool, _ what: StaticString) {
    if !ok { fatalError(what) }
  }
}
