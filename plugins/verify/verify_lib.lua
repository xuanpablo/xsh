-- Pure project detection and output trimming for the verify plugin. No maki
-- API, so the spec can exercise it directly.

local M = {}

M.CONTEXT_LINES = 3

-- Substrings worth keeping when a run failed. Everything before the first
-- match is setup noise (Compiling, Downloaded, progress bars). Lua patterns
-- have no alternation, so this is a plain substring list.
local FAILURE_MARKERS = {
  "FAILED", "FAILURES", "FAIL:", "ERROR", "error[", "error:", "panicked",
  "AssertionError", "assert", "✕", "✗", "failed",
}

local function failure_at(text)
  local first
  for _, marker in ipairs(FAILURE_MARKERS) do
    local at = text:find(marker, 1, true)
    if at and (not first or at < first) then
      first = at
    end
  end
  return first
end

--- { [path] = content-or-true } -> test command, or nil when unknown.
function M.detect(files)
  local just = files.justfile or files[".justfile"]
  if just then
    local recipes = type(just) == "string" and just or ""
    if recipes:match("^test[:%s]") or recipes:find("\ntest[:%s]") then
      return "just test"
    end
  end

  local package_json = files["package.json"]
  if package_json then
    local scripts = type(package_json) == "string" and package_json or ""
    if scripts:find('"test"') then
      return "npm test"
    end
  end

  if files["pyproject.toml"] or files["pytest.ini"] or files["setup.cfg"] or files["tox.ini"] then
    return "python -m pytest -q"
  end

  if files["Cargo.toml"] then
    return "cargo test --quiet"
  end

  return nil
end

function M.has_failure(text)
  return failure_at(text) ~= nil
end

--- Keep the tail from CONTEXT_LINES before the first failure; keep everything
--- when the run passed or no marker matched.
function M.focus_failures(text)
  local first = failure_at(text)
  if not first then
    return text
  end
  -- snap to the start of the failing line, then keep CONTEXT_LINES lines above
  local line_start = text:find("\n", 1, true) and (text:sub(1, first):match(".*\n()") or 1) or 1
  local back = 0
  local j = line_start - 1
  while back < M.CONTEXT_LINES and j > 0 do
    if text:byte(j) == string.byte("\n") then
      back = back + 1
    end
    j = j - 1
  end
  local start = j + 1
  if start == 1 then
    return text
  end
  return "(earlier output dropped)\n" .. text:sub(start)
end

return M
