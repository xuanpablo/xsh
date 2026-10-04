local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")
local ToolView = require("maki.tool_view")
local state = require("bg_state")

local OPTS = maki.api.register_options(output_limits.extend({}))

local REG = state.new()

local STARTED_FMT = "Started background job %d: %s\nPoll output with bash_output { id = %d }; stop it with kill_bash { id = %d }."
local RUNNING_FMT = "[running] %s"
local EXITED_FMT = "[exited, code %d] %s"
local NO_NEW_OUTPUT = "No new output."
local SKIPPED_FMT = "(%d earlier lines were dropped by the buffer)"
local KILLED_FMT = "Killed job %d: %s"
local STILL_EXITED_FMT = "Job %d had already exited (code %d)."
local UNKNOWN_JOB_FMT = "error: unknown job id %d"
local COMMAND_REQUIRED_ERR = "error: command is required"
local ID_REQUIRED_ERR = "error: id is required"
local TAIL_ERR = "error: tail must be >= 1"
local SEPARATOR = "──────"

local function finish_view(entry)
  if entry.view and not entry.finished then
    entry.finished = true
    entry.view:append({ { "Exit code: " .. tostring(entry.exit_code) .. " (background)", "dim" } })
    entry.view:finish()
  end
end

local function create_view(command)
  local buf = maki.ui.buf()
  local view = ToolView.new(buf, {
    max_lines = 10,
    keep = "tail",
    max_line_bytes = output_limits.DEFAULT_MAX_LINE_BYTES,
  })
  view:set_header({
    { command },
    { { SEPARATOR, "dim" } },
  })
  buf:on("click", function()
    view:toggle()
  end)
  return buf, view
end

local function find(id)
  local entry = REG.by_id[id]
  if entry then
    return entry
  end
  -- A plugin reload wiped REG but the process kept running; rebuild a stub
  -- from the host snapshot so polls and kills keep working.
  local info = maki.fn.jobinfo(id)
  if not info then
    return nil
  end
  entry = state.register(REG, info.name or ("job-" .. id), info.command, nil)
  state.bind(REG, entry, id)
  for _, line in ipairs(info.stdout_lines or {}) do
    state.append(entry, line)
  end
  for _, line in ipairs(info.stderr_lines or {}) do
    state.append(entry, line)
  end
  entry.exit_code = info.exit_code
  entry.read = #entry.lines
  return entry
end

local function status_line(entry)
  if entry.exit_code then
    return EXITED_FMT:format(entry.exit_code, state.label(entry))
  end
  return RUNNING_FMT:format(state.label(entry))
end

local function poll_output(entry, tail, max_lines, max_bytes)
  local lines, skipped = state.drain(entry)
  local output = table.concat(lines, "\n")
  if tail then
    output = output_limits.tail(output, tail)
  end
  output = truncate(output, max_lines, max_bytes)
  local parts = { status_line(entry) }
  if skipped > 0 then
    parts[#parts + 1] = SKIPPED_FMT:format(skipped)
  end
  if output ~= "" then
    parts[#parts + 1] = output
  elseif not entry.exit_code then
    parts[#parts + 1] = NO_NEW_OUTPUT
  end
  return table.concat(parts, "\n")
end

maki.api.register_tool({
  name = "bash_bg",
  kind = "execute",
  description = [[Start a bash command in the background and return immediately.
Use for dev servers, watch modes, long builds, or long test suites.
- Poll progress with `bash_output`; stop with `kill_bash`.
- The process keeps running across tool calls and agent turns.
- Provide a short `description` (3-5 words).]],
  schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "The bash command to run in the background", required = true },
      workdir = { type = "string", description = "Working directory (default: cwd)" },
      description = { type = "string", description = "Short description (3-5 words) of what the command does" },
    },
  },
  permission = "run",
  permission_scopes = function(input)
    if not input.command or input.command:match("^%s*$") then
      return nil
    end
    return { scopes = { input.command }, force_prompt = true }
  end,

  header = function(input)
    return (input.description or input.command) .. " (background)"
  end,

  restore = function(input, output, _is_error, _ctx)
    local buf = maki.ui.buf()
    buf:line({ { (input.description or input.command) .. " (background)" } })
    buf:line({ { SEPARATOR, "dim" } })
    buf:line({ { output, "dim" } })
    return buf
  end,

  handler = function(input, ctx)
    if not input.command or input.command:match("^%s*$") then
      return { llm_output = COMMAND_REQUIRED_ERR, is_error = true }
    end

    local name = state.next_name(REG)
    local entry = state.register(REG, name, input.command, input.description)
    local buf, view = create_view(input.command)
    entry.view = view

    local job_id, err = maki.fn.jobstart(input.command, {
      name = name,
      scope = "plugin",
      cwd = input.workdir,
      env = { GIT_TERMINAL_PROMPT = "0" },
      on_stdout = function(_, line)
        state.append(entry, line)
        view:append(line)
      end,
      on_stderr = function(_, line)
        state.append(entry, line)
        view:append(line)
      end,
      on_exit = function(_, code)
        entry.exit_code = code
        finish_view(entry)
      end,
    })
    if not job_id then
      REG.by_id[entry] = nil
      return { llm_output = "error: " .. err, is_error = true }
    end
    state.bind(REG, entry, job_id)

    return {
      llm_output = STARTED_FMT:format(job_id, state.label(entry), job_id, job_id),
      body = buf,
    }
  end,
})

maki.api.register_tool({
  name = "bash_output",
  kind = "execute",
  description = [[Read new output from a background job started with `bash_bg`.
Each call returns the lines produced since the previous call, plus the job's status.]],
  schema = {
    type = "object",
    properties = {
      id = { type = "integer", description = "Job id returned by bash_bg", required = true },
      tail = { type = "integer", description = "Return only the last N lines of the new output" },
    },
  },
  header = function(input)
    return "bash_output " .. tostring(input.id)
  end,

  handler = function(input, ctx)
    if not input.id then
      return { llm_output = ID_REQUIRED_ERR, is_error = true }
    end
    if input.tail and input.tail < 1 then
      return { llm_output = TAIL_ERR, is_error = true }
    end

    local entry = find(input.id)
    if not entry then
      return { llm_output = UNKNOWN_JOB_FMT:format(input.id), is_error = true }
    end

    local max_lines, max_bytes = output_limits.resolve(OPTS, ctx)
    return { llm_output = poll_output(entry, input.tail, max_lines, max_bytes) }
  end,
})

maki.api.register_tool({
  name = "kill_bash",
  kind = "execute",
  description = "Kill a background job started with `bash_bg`. Safe on already-exited jobs.",
  schema = {
    type = "object",
    properties = {
      id = { type = "integer", description = "Job id returned by bash_bg", required = true },
    },
  },
  header = function(input)
    return "kill_bash " .. tostring(input.id)
  end,

  handler = function(input)
    if not input.id then
      return { llm_output = ID_REQUIRED_ERR, is_error = true }
    end

    local entry = find(input.id)
    if not entry then
      return { llm_output = UNKNOWN_JOB_FMT:format(input.id), is_error = true }
    end

    if entry.exit_code then
      return { llm_output = STILL_EXITED_FMT:format(entry.id, entry.exit_code) }
    end

    maki.fn.jobstop(entry.id)
    entry.exit_code = entry.exit_code or -1
    finish_view(entry)
    return { llm_output = KILLED_FMT:format(entry.id, state.label(entry)) }
  end,
})
