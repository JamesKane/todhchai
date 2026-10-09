# Wayland protocol XML

Data, not code (principle 29): the protocol definitions `wlgen` reads to
generate `lib/wayland/generated`. Each file keeps its own license, the MIT
(Expat) license stated in its `<copyright>` element. They are unmodified.

| File | From (Fedora 44 package) | Upstream | sha256 (first 16) |
|---|---|---|---|
| `wayland.xml` | wayland-devel 1.26.0-1.fc44, `/usr/share/wayland/wayland.xml` | wayland 1.26.0 | cc860987e54f8d85 |
| `xdg-shell.xml` | wayland-protocols-devel 1.49-1.fc44, `stable/xdg-shell/` | wayland-protocols 1.49 | 7ba7f9c8473deee6 |
| `presentation-time.xml` | wayland-protocols-devel 1.49-1.fc44, `stable/presentation-time/` | wayland-protocols 1.49 | dffac93bcb2bb1d8 |
| `viewporter.xml` | wayland-protocols-devel 1.49-1.fc44, `stable/viewporter/` | wayland-protocols 1.49 | dcb12279a0374630 |
| `fractional-scale-v1.xml` | wayland-protocols-devel 1.49-1.fc44, `staging/fractional-scale/` | wayland-protocols 1.49 | 5941de5d28f427ec |

Copied 2026-10-09. To update: copy the new files over, record their
versions and hashes here, and regenerate (`CLAUDE.md`, "Wayland").
