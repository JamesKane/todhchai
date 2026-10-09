# Todhchai: directives for work in this repository

## License and SPDX identifiers

Todhchai is licensed under BSD-3-Clause ([LICENSE](LICENSE)), the OS and
the SDK alike.

Every source file starts with an SPDX identifier when it is created:

| Files | First line |
|---|---|
| Swift, C, C++, headers, Zig, Odin, assembly (`.S`), linker scripts, GLSL/HLSL | `// SPDX-License-Identifier: BSD-3-Clause` |
| Shell, Python, CMake, YAML, TOML, Makefiles | `# SPDX-License-Identifier: BSD-3-Clause` |
| Files with a shebang | the shebang, then the identifier on the second line |

- Generated source (`idlc` output, headers generated for the C ABI, tables
  generated from specifications) carries the identifier too: the generator
  emits it.
- When you edit a source file that lacks the identifier, add it.
- Third-party data (fonts, standards tables, community databases) keeps its
  own license and is never relabelled. It lives apart from source with its
  provenance recorded (principle 29, roadmap "Decided").
- Don't add a per-file copyright notice; [LICENSE](LICENSE) holds it.
