local lib = require("doctor_lib")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

case("plan_ok_when_commands_and_deps_present", function()
  local rows = lib.plan({ ["package.json"] = "{}" }, { node = true, npm = true }, { node_modules = true }, false)
  eq(#rows, 1)
  eq(rows[1].ok, true)
  eq(rows[1].ecosystem, "node")
end)

case("plan_reports_missing_command", function()
  local rows = lib.plan({ ["Cargo.toml"] = true }, {}, { target = true }, false)
  eq(rows[1].ok, false)
  eq(rows[1].problem:find("cargo") ~= nil, true)
end)

case("plan_reports_missing_deps_and_offers_fix", function()
  local rows = lib.plan({ ["package.json"] = "{}" }, { node = true, npm = true }, {}, false)
  eq(rows[1].ok, false)
  eq(rows[1].install, "npm install")
  eq(rows[1].fix_command, nil, "fix_command only when fix=true")
end)

case("plan_pyproject_requires_project_section", function()
  local none = lib.plan({ ["pyproject.toml"] = "[tool.black]\n" }, { python3 = true }, {}, false)
  eq(#none, 0)
  local some = lib.plan({ ["pyproject.toml"] = "[project]\nname = 'x'\n" }, { python3 = true }, {}, false)
  eq(#some, 1)
end)

case("format_reports_problems_with_fix_hint", function()
  local rows = lib.plan({ ["package.json"] = "{}" }, { node = true, npm = true }, {}, false)
  local text = lib.format(rows)
  eq(text:find("1 problem%(s%) found") ~= nil, true)
  eq(text:find("fix with: npm install") ~= nil, true)
end)

case("format_all_ok", function()
  local rows = lib.plan({ ["Cargo.toml"] = true }, { cargo = true }, { target = true }, false)
  eq(lib.format(rows):find("Environment ready") ~= nil, true)
end)

case("format_no_projects", function()
  eq(lib.format(lib.plan({}, {}, {}, false)):find("No supported project files") ~= nil, true)
end)

case("fix_commands_lists_installs", function()
  local rows = lib.plan({ ["package.json"] = "{}", ["go.mod"] = true }, { node = true, npm = true }, {}, true)
  local commands = lib.fix_commands(rows)
  eq(#commands, 1)
  eq(commands[1], "npm install")
end)

th.report()
