// SPDX-License-Identifier: BSD-3-Clause

// bin/catalog, natively (M3e): N0's client (Services.catalog).

import Launch
import LibSys
import Services
import Sys

@main struct CatalogProgram {
  static func main() {
    guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.user0)) else { exit(2) }
    do {
      try Services.catalog(try Startup(Handle(raw: raw)))
    } catch {
      exit(1)
    }
  }
}
