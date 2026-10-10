// SPDX-License-Identifier: BSD-3-Clause

// bin/spawn-probe: as little as a program can do (M3e's spawn-to-main
// measure, tests/native/N0Exit.swift). Its startup handle (PA_USER0) is an
// eventpair's end: main signals the peer at once, then the process exits.

import LibSys
import Sys

@main struct SpawnProbe {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    let end = Handle(raw: raw)
    try? end.signalPeer(set: Signals.signaled)
  }
}
