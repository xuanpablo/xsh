local checkers = require("diagnostics_checkers")
local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")

local OPTS = maki.api.register_options(output_limits.extend({
  timeout_secs = {
    default = 30,
    min = 1,
    desc = "Kill a single checker after this many seconds.",
  },
}))

local CONTINUE_FMT = [[Diagnostics ran on the files you just edited and found problems:

%s

Fix these before finishing.]]
local NO_DIAGNOSTICS = "No diagnostics found."
local CHECKER_TIMEOUT_FMT = "%s timed out after %ds"
local CHECKER_FAILED_FMT = "%s could not run: %s"

-- Paths touched by edit-kind tools since the last check.
local tracked = {}

local function track(input)
  if type(input) == "table" and type(input.path) == "string" and input.path ~= "" then
    tracked[input.path] = true
  end
end

maki.api.set_slot("tool.*.input", function(prev, input, ctx)
  if ctx.tool_kind == "edit" then
    track(input)
  end
  return prev(input, ctx)
end)

local function tracked_list()
  local paths = {}
  for path in pairs(tracked) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

local function run_one(plan, ctx)
  local argv = plan.argv
  local id, err = maki.fn.jobstart(argv, { cwd = plan.cwd })
  if not id and plan.fallback then
    argv = plan.fallback
    id, err = maki.fn.jobstart(argv, { cwd = plan.cwd })
  end
  if not id then
    return { name = plan.name, output = "", dirty = false, note = CHECKER_FAILED_FMT:format(plan.name, err) }
  end

  local result = maki.fn.jobwait(id, OPTS.timeout_secs * 1000)
  if not result then
    return {
      name = plan.name,
      output = "",
      dirty = false,
      note = CHECKER_TIMEOUT_FMT:format(plan.name, OPTS.timeout_secs),
    }
  end

  local max_lines, max_bytes = output_limits.resolve(OPTS, ctx)
  local raw = result.stdout ~= "" and result.stdout or result.stderr
  local output = checkers.filter_output(truncate(raw, max_lines, max_bytes), plan.filter)
  return { name = plan.name, output = output, dirty = result.exit_code ~= 0 and output ~= "" }
end

local function run_all(paths, workdir, ctx)
  local results = {}
  for _, plan in ipairs(checkers.plan(paths, workdir or maki.uv.cwd())) do
    results[#results + 1] = run_one(plan, ctx)
  end
  return results
end

maki.api.register_tool({
  name = "diagnostics",
  kind = "execute",
  description = [[Run fast linters (ruff, luacheck, shellcheck, tsc) on files and report problems.
- With no `paths`, checks the files edited since the last check.
- `tsc` runs once for the project and only reports the given files.
- Runs automatically when you finish a turn right after editing files, so most
  of the time you never need to call this.]],
  schema = {
    type = "object",
    properties = {
      paths = { type = "array", items = { type = "string" }, description = "Files to check (default: recently edited files)" },
      workdir = { type = "string", description = "Working directory for project-wide checkers (default: cwd)" },
    },
  },
  header = function(input)
    if input.paths then
      return "diagnostics " .. tostring(#input.paths) .. " files"
    end
    return "diagnostics (edited files)"
  end,

  handler = function(input, ctx)
    local paths = input.paths or tracked_list()
    if #paths == 0 then
      return { llm_output = NO_DIAGNOSTICS }
    end

    local report = checkers.format(run_all(paths, input.workdir, ctx))
    if report == "" then
      return { llm_output = NO_DIAGNOSTICS }
    end
    return { llm_output = report }
  end,
})

maki.api.set_slot("agent.stop", function(prev, stop, ctx)
  local paths = tracked_list()
  tracked = {}
  if #paths == 0 then
    return prev(stop, ctx)
  end

  local report = checkers.format(run_all(paths, nil, ctx))
  if report == "" then
    return prev(stop, ctx)
  end
  return { continue = CONTINUE_FMT:format(report) }
end)
