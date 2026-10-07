local guard = require("context_guard_lib")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

case("pct_computes_fill", function()
  eq(guard.pct(50_000, 200_000), 25)
  eq(guard.pct(200_000, 200_000), 100)
  eq(guard.pct(nil, 200_000), 0)
  eq(guard.pct(10, 0), 0)
end)

case("should_nudge_fires_once_at_threshold", function()
  eq(guard.should_nudge(160_000, 200_000, 80, false), true)
  eq(guard.should_nudge(160_000, 200_000, 80, true), false)
  eq(guard.should_nudge(100_000, 200_000, 80, false), false)
  eq(guard.should_nudge(159_999, 200_000, 80, false), false)
end)

case("nudge_message_includes_numbers", function()
  local msg = guard.nudge_message(180_000, 200_000, 90)
  eq(msg:find("Context is 90%% full %(threshold 90%%%)") ~= nil, true)
end)

case("compact_instructions_mention_keep_and_collapse", function()
  eq(guard.COMPACT_INSTRUCTIONS:find("Keep") ~= nil, true)
  eq(guard.COMPACT_INSTRUCTIONS:find("Collapse") ~= nil, true)
end)

th.report()
