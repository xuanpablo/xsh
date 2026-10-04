local checkers = require("diagnostics_checkers")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

case("ext_extracts_extension", function()
  eq(checkers.ext("src/a.ts"), "ts")
  eq(checkers.ext("no_ext"), nil)
end)

case("file_checker_maps_known_extensions_only", function()
  local function cmd(argv)
    return table.concat(argv, " ")
  end
  eq(cmd(checkers.file_checker("a.py")), "ruff check a.py")
  eq(cmd(checkers.file_checker("a.lua")), "luacheck a.lua")
  eq(cmd(checkers.file_checker("a.sh")), "shellcheck a.sh")
  eq(checkers.file_checker("a.rb"), nil)
end)

case("needs_tsc_detects_js_family", function()
  eq(checkers.needs_tsc({ "a.py", "b.tsx" }), true)
  eq(checkers.needs_tsc({ "a.py", "b.rs" }), false)
end)

case("plan_covers_each_file_plus_one_tsc", function()
  local plans = checkers.plan({ "a.py", "b.py", "c.ts", "d.lua" }, "/repo")
  local names = {}
  for i, plan in ipairs(plans) do
    names[i] = plan.name
  end
  eq(table.concat(names, ","), "ruff,ruff,luacheck,tsc")
  eq(table.concat(plans[4].argv, " "), "npx --no-install tsc --noEmit")
  eq(table.concat(plans[4].fallback, " "), "tsc --noEmit")
  eq(plans[4].cwd, "/repo")
  eq(plans[4].filter[1], "a.py")
end)

case("plan_without_js_files_has_no_tsc", function()
  eq(#checkers.plan({ "a.py" }, nil), 1)
end)

case("mentions_matches_full_path_and_basename", function()
  eq(checkers.mentions("src/a.ts(1,5): error TS1: bad", { "src/a.ts" }), true)
  eq(checkers.mentions("src/a.ts(1,5): error TS1: bad", { "other/a.ts" }), true)
  eq(checkers.mentions("src/b.ts(1,5): error TS1: bad", { "src/a.ts" }), false)
end)

case("filter_output_keeps_only_mentioned_lines", function()
  local text = "src/a.ts(1,1): error TS1: bad\nsrc/b.ts(2,2): error TS2: other"
  eq(checkers.filter_output(text, { "a.ts" }), "src/a.ts(1,1): error TS1: bad")
end)

case("filter_output_passes_through_without_filter", function()
  eq(checkers.filter_output("anything", nil), "anything")
end)

case("format_joins_dirty_results_only", function()
  local results = {
    { name = "ruff", output = "a.py:1:1 E (F401)", dirty = true },
    { name = "tsc", output = "", dirty = false },
    { name = "luacheck", output = "c.lua:2:3", dirty = true },
  }
  eq(checkers.format(results), "ruff:\na.py:1:1 E (F401)\nluacheck:\nc.lua:2:3")
end)

case("any_dirty_needs_one_dirty_result", function()
  eq(checkers.any_dirty({ { dirty = false }, { dirty = true } }), true)
  eq(checkers.any_dirty({ { dirty = false } }), false)
  eq(checkers.any_dirty({}), false)
end)

th.report()
