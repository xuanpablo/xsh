-- Structured-output story: the subagent gets a session-local structured_output
-- tool whose handler validates and captures the result as closure upvalues.
-- Invalid input is an inline tool error the model can fix in the same run.
-- This plugin owns structured output and subagent concurrency; Rust exposes
-- primitives only (`maki.agent.session`, `maki.json.schema_validator`,
-- `maki.async.semaphore`).
--
-- Report tasks swap structured_output for task_report: the child files a
-- report, the parent gets it as a distinct block plus a task id, and `resume`
-- continues that parked child with a follow-up prompt. `fork_depth` seeds a
-- fresh child with the tail of the parent transcript instead of a blank
-- history.
--
-- It also owns the /tasks picker over the subagents spawned here: picker.lua
-- registers the command and the keymap when this file is loaded, so the two
-- cannot be enabled apart and left pointing at each other's absence.

local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")
require("picker")

local STRUCTURED_OUTPUT_NAME = "structured_output"
local STRUCTURED_OUTPUT_DESCRIPTION = "Report your final result. Call it exactly once when your task is complete."
local STRUCTURED_OUTPUT_ACK = "Output recorded."
local STRUCTURED_OUTPUT_PROMPT_SUFFIX = "\n\nWhen finished, call the structured_output tool with your final result."
local TASK_REPORT_NAME = "task_report"
local TASK_REPORT_DESCRIPTION =
  "Deliver your final report. Call it exactly once, after your work is done and before you finish."
local TASK_REPORT_ACK = "Report recorded."
local TASK_REPORT_PROMPT_SUFFIX = "\n\nWhen finished, call the task_report tool with your final report."
local TASK_REPORT_SCHEMA = {
  type = "object",
  required = { "summary" },
  additionalProperties = false,
  properties = {
    summary = { type = "string", description = "Concise summary of the outcome, with file:line refs where useful." },
    details = { type = "string", description = "Optional supporting findings, caveats, or next steps." },
  },
}
local NUDGE_REPORT = "You did not call the task_report tool. Call it now with your final report."
local REPORT_MISSING_ERROR = "subagent finished without calling task_report"
local RESUME_NOT_FOUND_ERROR = "no resumable task with that id (expired or not a report task)"
local FORK_DEPTH_ERROR = "fork_depth must be a positive integer"
local REPORT_HEADING = "## Task report"
local TASK_ID_LABEL = 'Task id: %s. Resume it with task(resume = "%s").'
local TASK_ID_PREFIX = "task-"
local MAX_RESUMABLE = 4
local MAX_NUDGES = 2
local MAX_SCHEMA_ERRORS = 3
local SCHEMA_COMPILE_ERROR = "invalid output_schema"
local SCHEMA_ROOT_ERROR = "output_schema must have type object"
local STRUCTURED_MISSING_ERROR = "subagent finished without calling structured_output"
local STRUCTURED_INVALID_ERROR = "subagent result does not match output_schema"
local SUMMARY_MISSING_ERROR = "subagent finished without providing a summary"
local NUDGE_MISSING =
  "You did not call the structured_output tool. Call it now with your final result matching its input schema."
local NUDGE_SUMMARY =
  "You finished your work but did not provide a summary. Reply with a concise summary of what you did and found."
local INVALID_INPUT_PREFIX =
  "Input does not match the required schema. Fix the errors and call structured_output again:\n"
local BODY_INDENT_COLS = 4
local MIN_MD_WIDTH = 20
local DEFAULT_OUTPUT_LINES = 5

local description = [[Launch an autonomous subagent to perform tasks independently. Best combined with batch.

Subagent types (set via `subagent_type`):
- `research` (default): Read-only tools. For codebase exploration or gathering context.
- `general`: Full tool access. For delegating implementation work.

Notes:
1. Launch multiple tasks concurrently when possible.
2. The agent's result is not visible to the user. Summarize it in your response.
3. Each invocation starts fresh - inline any needed context into the prompt. Pass `fork_depth` to instead seed it with the tail of this session's transcript.
4. Tell it to return concise summaries with file:line refs, not full file contents.
5. `report = true` requires the subagent to file a `task_report` before finishing and returns a task id; `resume` continues that subagent with a follow-up.
]]

local opts = maki.api.register_options({
  max_concurrent = { default = 8, min = 1, desc = "Max concurrently running subagents." },
  allow_model = {
    default = false,
    desc = "Expose a `model` input that overrides the subagent model. Only enable if you trust callers to pick an exact model themselves.",
  },
})

local schema = {
  type = "object",
  required = { "description", "prompt" },
  additionalProperties = false,
  properties = {
    description = {
      type = "string",
      description = "Short (3-5 words) description of the task",
    },
    prompt = {
      type = "string",
      description = "Detailed task prompt for the agent",
    },
    subagent_type = {
      type = "string",
      description = 'Subagent type: "research" (read-only, default) or "general" (can modify files)',
    },
    model_tier = {
      type = "string",
      description = 'Model tier (optional, omit to use current model, capped at current tier):\n- "strong" (e.g. Opus): Deep reasoning, complex architecture, subtle bugs, most critical sections. ~5x cost of medium.\n- "medium" (e.g. Sonnet): Balanced. Refactors, features, multi-file changes.\n- "weak" (e.g. Haiku): Fast/cheap. Search, summarize, boilerplate, simple edits.',
    },
    thinking = {
      description = "Thinking: off|adaptive|minimal|low|medium|high|xhigh|max|int budget. Omit to inherit parent; capped at parent.",
    },
    output_schema = {
      description = "JSON Schema (object) the subagent's final result must match. When set, the result is returned as a validated JSON string.",
    },
    report = {
      type = "boolean",
      description = "Require the subagent to call its task_report tool before finishing. The report comes back as a distinct block plus a task id you can resume with `resume`.",
    },
    resume = {
      type = "string",
      description = "Task id returned by an earlier report task. Continues that subagent with this prompt instead of spawning a new one.",
    },
    fork_depth = {
      type = "integer",
      description = "Fork: seed the subagent with the last N messages of this session's transcript (text only) instead of starting blank. Omit to spawn fresh.",
    },
  },
}

-- Only advertise `model` when the plugin opts in: it costs tokens in every
-- task schema, and an off-by-default flag keeps the common path lean.
if opts.allow_model then
  schema.properties.model = {
    type = "string",
    description = 'Exact model spec, e.g. "ollama/glm-5.2". You tell maki the model; maki will not guess. Overrides model_tier.',
  }
end

local examples = {
  {
    description = "Find auth middleware",
    prompt = "Search the codebase for authentication middleware. Return file paths and a summary of how auth is implemented.",
    model_tier = "weak",
  },
}

-- Process-wide cap on concurrent subagents.
local semaphore = maki.async.semaphore(opts.max_concurrent)

local function bounded_errors(errors)
  local out = {}
  for i = 1, math.min(#errors, MAX_SCHEMA_ERRORS) do
    out[i] = errors[i]
  end
  return table.concat(out, "\n")
end

-- Finished report-mode children stay parked here so the parent can resume
-- them; the cap closes the oldest when full, since a parked session holds a
-- cancel slot and an event relay open. The slot is the same table the child's
-- task_report handler writes into, so a resumed run files into it too.
local resumed = {}
local resumed_order = {}
local next_task_seq = 0

local function park(id, entry)
  if resumed[id] then
    return
  end
  resumed[id] = entry
  resumed_order[#resumed_order + 1] = id
  while #resumed_order > MAX_RESUMABLE do
    local evicted = table.remove(resumed_order, 1)
    local evicted_entry = resumed[evicted]
    resumed[evicted] = nil
    evicted_entry.sess:close()
  end
end

local function report_output(id, report)
  local parts = { string.format(TASK_ID_LABEL, id, id), report.summary }
  if report.details and report.details ~= "" then
    parts[#parts + 1] = report.details
  end
  return table.concat(parts, "\n\n")
end

local function handler(input, ctx)
  if input.resume then
    local entry = resumed[input.resume]
    if not entry then
      return { llm_output = RESUME_NOT_FOUND_ERROR, is_error = true }
    end
    local permit = semaphore:acquire()
    local ok, out = pcall(function()
      entry.slot.report = nil
      local result, err = entry.sess:prompt(input.prompt .. TASK_REPORT_PROMPT_SUFFIX)
      local retries = 0
      while not err and not entry.slot.report and retries < MAX_NUDGES do
        retries = retries + 1
        result, err = entry.sess:prompt(NUDGE_REPORT)
      end
      if err then
        return { llm_output = "sub-agent error: " .. err, is_error = true }
      end
      local report = entry.slot.report
      if not report then
        return { llm_output = REPORT_MISSING_ERROR, is_error = true }
      end
      return {
        llm_output = report_output(input.resume, report),
        format = "report",
        state = { report = true },
      }
    end)
    permit:release()
    if not ok then
      error(out, 0)
    end
    return out
  end

  local subagent_type = input.subagent_type or "research"
  if subagent_type ~= "research" and subagent_type ~= "general" then
    return { llm_output = "unknown subagent type: " .. subagent_type, is_error = true }
  end

  -- Compile early: a bad schema costs zero tokens.
  local validator
  if input.output_schema then
    if type(input.output_schema) ~= "table" or input.output_schema.type ~= "object" then
      return { llm_output = SCHEMA_ROOT_ERROR, is_error = true }
    end
    local compile_err
    validator, compile_err = maki.json.schema_validator(input.output_schema)
    if compile_err then
      return { llm_output = SCHEMA_COMPILE_ERROR .. ": " .. compile_err, is_error = true }
    end
  end

  local report_mode = input.report == true and validator == nil
  local fork_depth = input.fork_depth
  if fork_depth ~= nil and (type(fork_depth) ~= "number" or fork_depth < 1 or fork_depth % 1 ~= 0) then
    return { llm_output = FORK_DEPTH_ERROR, is_error = true }
  end
  next_task_seq = next_task_seq + 1
  local task_id = TASK_ID_PREFIX .. next_task_seq

  local model, model_err = maki.agent.resolve_model(ctx, {
    tier = input.model_tier,
    spec = opts.allow_model and input.model or nil,
  })
  if model_err then
    return { llm_output = model_err, is_error = true }
  end

  local audience = subagent_type == "research" and "research_sub" or "general_sub"
  local prompt_id = subagent_type == "research" and "research" or "general"
  local system, system_err = maki.agent.system_prompt(ctx, {
    prompt_id = prompt_id,
    instructions = true,
  })
  if system_err then
    return { llm_output = system_err, is_error = true }
  end

  local tool_defs, tools_err = maki.agent.tools(ctx, {
    audience = audience,
    spec = model.spec,
  })
  if tools_err then
    return { llm_output = tools_err, is_error = true }
  end

  local captured, last_errors
  local report_slot = {}
  local local_tools
  if validator then
    local_tools = {
      [STRUCTURED_OUTPUT_NAME] = {
        description = STRUCTURED_OUTPUT_DESCRIPTION,
        input_schema = input.output_schema,
        handler = function(value)
          local errs = validator:validate(value)
          if errs then
            last_errors = bounded_errors(errs)
            return nil, INVALID_INPUT_PREFIX .. last_errors
          end
          captured = value
          return STRUCTURED_OUTPUT_ACK
        end,
      },
    }
  elseif report_mode then
    local_tools = {
      [TASK_REPORT_NAME] = {
        description = TASK_REPORT_DESCRIPTION,
        input_schema = TASK_REPORT_SCHEMA,
        handler = function(value)
          report_slot.report = value
          return TASK_REPORT_ACK
        end,
      },
    }
  end

  local permit = semaphore:acquire()
  -- Declared out here so the epilogue closes it on every path: left to the
  -- garbage collector it keeps the subagent's event relay alive on an idle VM.
  local sess

  -- pcall so a raised error cannot leak the permit or the session.
  local ok, out = pcall(function()
    local sess_err
    sess, sess_err = maki.agent.session(ctx, {
      model_spec = model.spec,
      system = system,
      tools = tool_defs,
      local_tools = local_tools,
      audience = audience,
      name = input.description,
      thinking = input.thinking,
      fork_last = fork_depth,
    })
    if sess_err then
      return { llm_output = sess_err, is_error = true }
    end

    local message = input.prompt
    if validator then
      message = message .. STRUCTURED_OUTPUT_PROMPT_SUFFIX
    elseif report_mode then
      message = message .. TASK_REPORT_PROMPT_SUFFIX
    end

    local result, err = sess:prompt(message)
    local retries = 0
    while not err and retries < MAX_NUDGES do
      if validator and not captured then
        retries = retries + 1
        result, err = sess:prompt(NUDGE_MISSING)
      elseif report_mode and not report_slot.report then
        retries = retries + 1
        result, err = sess:prompt(NUDGE_REPORT)
      elseif not validator and not report_mode and result.text == "" then
        retries = retries + 1
        result, err = sess:prompt(NUDGE_SUMMARY)
      else
        break
      end
    end

    if err then
      -- A result alongside the error means the run was cut short after
      -- streaming some text, and half a transcript beats a bare error.
      if result then
        return {
          llm_output = "sub-agent interrupted (" .. err .. "). Partial output:\n" .. result.text,
          is_error = true,
        }
      end
      return { llm_output = "sub-agent error: " .. err, is_error = true }
    end
    if validator and not captured then
      local msg = last_errors and (STRUCTURED_INVALID_ERROR .. ":\n" .. last_errors) or STRUCTURED_MISSING_ERROR
      return { llm_output = msg, is_error = true }
    end
    if report_mode and not report_slot.report then
      return { llm_output = REPORT_MISSING_ERROR, is_error = true }
    end
    if not validator and not report_mode and result.text == "" then
      return { llm_output = SUMMARY_MISSING_ERROR, is_error = true }
    end
    if report_mode then
      return {
        llm_output = report_output(task_id, report_slot.report),
        format = "report",
        state = { report = true },
      }
    end
    return { llm_output = captured and maki.json.encode(captured) or result.text, format = "markdown" }
  end)

  if sess then
    if report_mode and report_slot.report then
      park(task_id, { sess = sess, slot = report_slot })
    else
      sess:close()
    end
  end
  permit:release()
  if not ok then
    error(out, 0)
  end
  return out
end

local function header(input)
  return input.description
end

-- Standalone runs render markdown on the Rust side (format = "markdown");
-- this mirrors that for restore and batch children, which build the body here.
local function restore(_input, output, is_error, ctx)
  local st = ctx:state()
  if st and st.report then
    output = REPORT_HEADING .. "\n\n" .. output
  end
  local tol = ctx:tool_output_lines()
  return ToolView.restore_markdown(output, is_error, {
    max_lines = (tol and tol.task) or DEFAULT_OUTPUT_LINES,
    keep = "head",
    max_line_bytes = output_limits.DEFAULT_MAX_LINE_BYTES,
    width = math.max(maki.ui.terminal_size().cols - BODY_INDENT_COLS, MIN_MD_WIDTH),
  })
end

maki.api.register_tool({
  name = "task",
  description = description,
  kind = "execute",
  audiences = { "main", "workflow" },
  examples = examples,
  schema = schema,
  handler = handler,
  header = header,
  restore = restore,
})
