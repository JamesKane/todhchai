# Unicode Character Database (part)

Data, not code (principle 29): the files `ucdgen` reads to generate
`lib/unicode/generated/Tables.swift`, and the conformance test data. They
keep their own license, the Unicode License v3 (`LICENSE.txt`, copied
from the package), and are unmodified.

| File | sha256 (first 16) | Used for |
|---|---|---|
| `UnicodeData.txt` | 0736451de439ae7b | canonical combining classes and decompositions |
| `CompositionExclusions.txt` | c759b100e9ae8960 | the script-specific and post-composition-version exclusions (UAX #15 §5) |
| `CaseFolding.txt` | a004797658a457be | full case folding (statuses C and F) |
| `NormalizationTest.txt` | 25a50d816764b04a | the conformance test (`tests/unicode`) |
| `LICENSE.txt` | e7a93b009565cfce | — |

From Fedora 44's `unicode-ucd-18.0.0-2.fc44` (`/usr/share/unicode/ucd`), which
packages Unicode 18.0.0 from unicode.org. Copied 2026-10-09. To update:
copy the new files over, record their version and hashes here, regenerate
(`CLAUDE.md`, "Unicode"), and run the conformance test.
