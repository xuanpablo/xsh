local verify_lib = require("verify_lib")
local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")

local OPTS = maki.api.register_options(output_limits.extend({
  timeout_secs = {
    default = 300,
    min = 5,
    desc = "Kill the test run after this many seconds.",
  },
}))

local NO_RUNNER_ERR = "error: could not detect a test runner. Pass `command` (supported: justfile test recipe, npm test, pytest, cargo test)."
local PASSED = "All tests passed."

local function detect_command(workdir)
  local names = { "justfile", ".justfile", "package.json", "pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini", "Cargo.toml" }
  local files = {}
  for _, name in ipairs(names) do
    local path = workdir and maki.fs.joinpath(workdir, name) or name
    local content = maki.fs.read(path)
    if content then
      files[name] = content
    end
  end
  return verify_lib.detect(files)
end

maki.api.register_tool({
  name = "verify",
  kind = "execute",
  description = [[Run the project's tests and get failures back, trimmed to the relevant part.
- Autodetects the runner: justfile `test` recipe, npm test, pytest, cargo test.
- Pass `command` to override, e.g. `just lint` or `pytest tests/test_x.py -q`.
- Prefer this over bash for test runs: the output is failure-focused.]],
  schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "Test command to run (default: autodetect)" },
      workdir = { type = "string", description = "Working directory (default: cwd)" },
      tail = { type = "integer", description = "Return only the last N lines" },
    },
  },
  permission = "run",
  permission_scopes = function(input)
    local command = input.command
    if not command or command:match("^%s*$") then
      return nil
    end
    return { command, force_prompt = true }
  end,

  header = function(input)
    return input.command or "verify (autodetect)"
  end,

  handler = function(input, ctx)
    local command = input.command
    if not command or command:match("^%s*$") then
      command = detect_command(input.workdir)
      if not command then
        return { llm_output = NO_RUNNER_ERR, is_error = true }
      end
    end

    local job_id, err = maki.fn.jobstart(command, {
      cwd = input.workdir,
      env = { GIT_TERMINAL_PROMPT = "0" },
    })
    if not job_id then
      return { llm_output = "error: " .. err, is_error = true }
    end

    local result = maki.fn.jobwait(job_id, OPTS.timeout_secs * 1000)
    if not result then
      return { llm_output = "error: test run timed out after " .. OPTS.timeout_secs .. "s", is_error = true }
    end

    local max_lines, max_bytes = output_limits.resolve(OPTS, ctx)
    local output = result.stdout ~= "" and result.stdout or result.stderr
    if result.exit_code ~= 0 then
      output = verify_lib.focus_failures(output)
    end
    if input.tail then
      output = output_limits.tail(output, input.tail)
    end
    output = truncate(output, max_lines, max_bytes)

    if result.exit_code == 0 then
      return { llm_output = output == "" and PASSED or output }
    end
    local exit_line = "Exit code: " .. result.exit_code
    return {
      llm_output = output == "" and exit_line or output .. "\n" .. exit_line,
      is_error = true,
    }
  end,
})
