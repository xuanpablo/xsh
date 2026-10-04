-- Pure planning and formatting for the diagnostics plugin. No maki API, so
-- the spec can exercise every branch directly.

local M = {}

M.TSC_EXTS = { ts = true, tsx = true, js = true, jsx = true, mjs = true, cjs = true }

-- extension -> argv builder. `tsc` is project-wide and handled separately.
local FILE_CHECKERS = {
  py = function(path)
    return { "ruff", "check", path }
  end,
  lua = function(path)
    return { "luacheck", path }
  end,
  sh = function(path)
    return { "shellcheck", path }
  end,
}

function M.ext(path)
  return path:match("%.(%w+)$")
end

function M.file_checker(path)
  local build = FILE_CHECKERS[M.ext(path)]
  if not build then
    return nil
  end
  return build(path)
end

function M.needs_tsc(paths)
  for _, path in ipairs(paths) do
    if M.TSC_EXTS[M.ext(path)] then
      return true
    end
  end
  return false
end

--- One check to run: { name, argv, cwd, filter? }. `filter` lists the paths a
--- project-wide checker's output must mention to be reported.
function M.plan(paths, workdir)
  local plans = {}
  local seen = {}
  for _, path in ipairs(paths) do
    local argv = M.file_checker(path)
    if argv and not seen[argv[1] .. path] then
      seen[argv[1] .. path] = true
      plans[#plans + 1] = { name = argv[1], argv = argv, cwd = workdir }
    end
  end
  if M.needs_tsc(paths) then
    plans[#plans + 1] = {
      name = "tsc",
      argv = { "npx", "--no-install", "tsc", "--noEmit" },
      fallback = { "tsc", "--noEmit" },
      cwd = workdir,
      filter = paths,
    }
  end
  return plans
end

--- tsc reports every project error; keep only lines about the edited files.
--- tsc prints paths relative to its cwd, so match on the path itself and on
--- its tail (`src/a.ts` matches `a.ts` and `src/a.ts`).
function M.mentions(line, paths)
  for _, path in ipairs(paths) do
    local base = path:match("[^/\\]+$") or path
    if line:find(path, 1, true) or line:find(base, 1, true) then
      return true
    end
  end
  return false
end

function M.filter_output(text, filter)
  if not filter then
    return text
  end
  local kept = {}
  for line in text:gmatch("[^\n]+") do
    if M.mentions(line, filter) then
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept, "\n")
end

--- results: array of { name, output, dirty }. Output is already filtered
--- and `dirty` already means "exit code nonzero AND output survived the
--- filter", so formatting only decides layout.
function M.format(results)
  local parts = {}
  for _, result in ipairs(results) do
    if result.dirty then
      parts[#parts + 1] = result.name .. ":\n" .. result.output
    end
  end
  return table.concat(parts, "\n")
end

function M.any_dirty(results)
  for _, result in ipairs(results) do
    if result.dirty then
      return true
    end
  end
  return false
end

return M
