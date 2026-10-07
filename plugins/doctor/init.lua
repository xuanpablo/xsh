local doctor_lib = require("doctor_lib")

local MARKERS = { "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt" }
local DEP_DIRS = { "node_modules", "target", ".venv" }
local COMMANDS = { "node", "npm", "cargo", "go", "python3" }

local DESCRIPTION = [[Check that this project's toolchain is installed and dependencies are present.
Covers node, rust, go, and python projects. With `fix = true`, runs the detected install
commands (npm install, cargo fetch, ...). Run this before starting work in an unfamiliar checkout.]]

local function probe_files(workdir)
  local present = {}
  for _, name in ipairs(MARKERS) do
    local path = workdir and maki.fs.joinpath(workdir, name) or name
    local content = maki.fs.read(path)
    if content then
      present[name] = content
    end
  end
  return present
end

local function probe_dirs(workdir)
  local dirs = {}
  for _, name in ipairs(DEP_DIRS) do
    local path = workdir and maki.fs.joinpath(workdir, name) or name
    if maki.fs.metadata(path) then
      dirs[name] = true
    end
  end
  return dirs
end

local function probe_commands()
  local available = {}
  local id, err = maki.fn.jobstart(
    "for c in " .. table.concat(COMMANDS, " ") .. "; do command -v $c >/dev/null 2>&1 && echo $c; done",
    {}
  )
  if not id then
    return available, err
  end
  local result = maki.fn.jobwait(id, 10000)
  if not result then
    return available, "command probe timed out"
  end
  for line in result.stdout:gmatch("[^\n]+") do
    available[line] = true
  end
  return available, nil
end

maki.api.register_tool({
  name = "doctor",
  kind = "execute",
  description = DESCRIPTION,
  schema = {
    type = "object",
    properties = {
      fix = { type = "boolean", description = "Run the install commands for any missing dependencies" },
      workdir = { type = "string", description = "Project directory (default: cwd)" },
    },
  },
  header = function(input)
    return input.fix and "doctor (fix)" or "doctor"
  end,

  handler = function(input, ctx)
    local available, probe_err = probe_commands()
    if probe_err then
      return { llm_output = "error: " .. probe_err, is_error = true }
    end

    local rows = doctor_lib.plan(probe_files(input.workdir), available, probe_dirs(input.workdir), false)
    local report = doctor_lib.format(rows)

    if input.fix then
      local commands = doctor_lib.fix_commands(rows)
      local ran = {}
      for _, command in ipairs(commands) do
        local id, err = maki.fn.jobstart(command, { cwd = input.workdir })
        if not id then
          ran[#ran + 1] = command .. ": failed to start (" .. err .. ")"
        else
          local result = maki.fn.jobwait(id, 300000)
          if result and result.exit_code == 0 then
            ran[#ran + 1] = command .. ": ok"
          else
            local tail = result and result.stderr ~= "" and result.stderr or (result and result.stdout) or "timed out"
            ran[#ran + 1] = command .. ": FAILED\n" .. tail
          end
        end
      end
      if #ran > 0 then
        report = report .. "\n\nFix runs:\n" .. table.concat(ran, "\n")
      end
    end

    return { llm_output = report }
  end,
})
