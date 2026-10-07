-- Pure planning for the doctor plugin: given what is on disk and which
-- commands exist, produce a checklist. No maki API, so the spec can exercise
-- it directly.

local M = {}

local ECOSYSTEMS = {
  {
    name = "node",
    marker = "package.json",
    commands = { "node", "npm" },
    dep_dir = "node_modules",
    install = "npm install",
  },
  {
    name = "rust",
    marker = "Cargo.toml",
    commands = { "cargo" },
    dep_dir = "target",
    install = "cargo fetch",
  },
  {
    name = "go",
    marker = "go.mod",
    commands = { "go" },
    dep_dir = nil,
    install = "go mod download",
  },
  {
    name = "python",
    marker = "pyproject.toml",
    marker_content = "[project]",
    commands = { "python3" },
    dep_dir = ".venv",
    install = "python3 -m pip install -e .",
  },
  {
    name = "python",
    marker = "requirements.txt",
    commands = { "python3" },
    dep_dir = nil,
    install = "python3 -m pip install -r requirements.txt",
  },
}

--- present: { [path] = content-or-true }; available: { [command] = true };
--- dirs: { [dir] = true }. Returns a list of rows:
---   { ecosystem, ok, problem, fix_command? }
--- `fix` promotes every fixable problem to a fix_command; without it problems
--- are reported with the command the model can run later.
function M.plan(present, available, dirs, fix)
  local rows = {}
  for _, eco in ipairs(ECOSYSTEMS) do
    local marker = present[eco.marker]
    if marker then
      if eco.marker_content and type(marker) == "string" and not marker:find(eco.marker_content, 1, true) then
        -- marker present but the ecosystem section is not; not this toolchain
        marker = nil
      end
    end
    if marker then
      for _, command in ipairs(eco.commands) do
        if not available[command] then
          rows[#rows + 1] = {
            ecosystem = eco.name,
            ok = false,
            problem = "required command not found: " .. command,
          }
        end
      end
      if eco.dep_dir and not dirs[eco.dep_dir] then
        rows[#rows + 1] = {
          ecosystem = eco.name,
          ok = false,
          problem = "dependencies not installed (no " .. eco.dep_dir .. "/)",
          fix_command = fix and eco.install or nil,
          install = eco.install,
        }
      end
      if #rows == 0 or rows[#rows].ecosystem ~= eco.name then
        rows[#rows + 1] = { ecosystem = eco.name, ok = true }
      end
    end
  end
  return rows
end

--- rows -> report text. Fixable rows carry their install command either way,
--- so the model knows what to run when `fix` was left off.
function M.format(rows)
  if #rows == 0 then
    return "No supported project files found (package.json, Cargo.toml, go.mod, pyproject.toml, requirements.txt)."
  end
  local parts = {}
  local problems = 0
  for _, row in ipairs(rows) do
    if row.ok then
      parts[#parts + 1] = "OK      " .. row.ecosystem
    else
      problems = problems + 1
      local line = "PROBLEM " .. row.ecosystem .. ": " .. row.problem
      if row.install then
        line = line .. "\n        fix with: " .. row.install
      end
      parts[#parts + 1] = line
    end
  end
  local summary = problems == 0 and "Environment ready." or (problems .. " problem(s) found.")
  return summary .. "\n" .. table.concat(parts, "\n")
end

--- The install commands to run for `fix = true`.
function M.fix_commands(rows)
  local commands = {}
  for _, row in ipairs(rows) do
    if not row.ok and row.install then
      commands[#commands + 1] = row.install
    end
  end
  return commands
end

return M
