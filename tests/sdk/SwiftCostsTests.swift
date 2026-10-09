// SPDX-License-Identifier: BSD-3-Clause

// Swift's costs are counted exactly (docs/performance.md, "Swift costs").

import TDLinux
import Testing

final class Box {
  var value = 0
}

@inline(never) func make() -> Box { Box() }
@inline(never) func keep(_ b: Box) -> [Box] { [b, b] }

@Test func retainsAndAllocationsAreCounted() {
  #expect(td_swift_costs_install() == 0)
  let before = td_swift_costs_read()
  let boxes = keep(make())  // the Box, and the array's storage
  let after = td_swift_costs_read()
  #expect(boxes.count == 2)
  #expect(after.allocations - before.allocations >= 2)
  #expect(after.retains - before.retains >= 1)
}

@Test func nothingCountsWhereNothingHappens() {
  #expect(td_swift_costs_install() == 0)
  var sum = 0
  let before = td_swift_costs_read()
  for i in 0..<1000 { sum &+= i }
  let after = td_swift_costs_read()
  #expect(sum == 499_500)
  #expect(after.allocations == before.allocations)
  #expect(after.retains == before.retains)
}
