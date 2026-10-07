-- The workflow tool: the model writes a small Lua state machine (steps that
-- call maki tools or subagents) and this plugin drives it through the bounded
-- loop in `workflow_engine.lua`, checkpointing between steps so an aborted
-- run resumes where it stopped.

local engine = require("maki.workflow_engine")

local DESCRIPTION = [[Run a multi-step workflow defined as a Lua state machine.

Write a script that returns a table:

```
return {
  start = "fetch",
  steps = {
    fetch = function(ctx, state)
      local out = ctx:call("websearch", { query = state.query })
      ctx.log("found results")
      return "summarize", { query = state.query, raw = out }
    end,
    summarize = function(ctx, state)
      local text, err = ctx:call("task", {
        description = "summarize",
        prompt = state.raw,
      })
      return nil, { summary = text }
    end,
  },
}
```

Rules:
- A step receives `(ctx, state)`; `ctx:call(tool, params)` calls any tool
  (including `task` for subagents) under the step's time budget, `ctx.log(msg)`
  records a note for the report. Return the next step name (or nil to finish)
  and optionally a replacement state.
- `state` must be JSON-encodable; it is carried across steps and checkpoints.
- The same step twice with an identical state aborts the run (loop detection).
- On abort (error, loop, budget or step limit) the output carries a checkpoint:
  call workflow again with the same script and `resume` set to that JSON to
  continue from the failed step.]]

local SCRIPT_REQUIRED_ERR = "script is required"
local SCRIPT_COMPILE_ERR = "script does not compile: "
local SCRIPT_RETURN_ERR = "script must return a workflow table: "
local SCRIPT_MISMATCH_ERR = "resume checkpoint belongs to a different script; pass the same script"
local RESUME_DECODE_ERR = "resume is not a valid checkpoint: "
local RESUME_FINAL_ERR = "checkpoint's step was the last one; nothing to resume, rerun from scratch if needed"

local STEP_TIMEOUT_MIN_SECS = 5
local MAX_STEPS_MIN = 1
local CHECKPOINT_FENCE = "```json"

local function schema()
  return {
    type = "object",
    required = { "script" },
    properties = {
      script = {
        type = "string",
        description = "Lua source returning { start = name, steps = { name = function(ctx, state) ... end } }",
      },
      resume = {
        type = "string",
        description = "Checkpoint JSON from an aborted run; the script must be identical",
      },
      max_steps = {
        type = "integer",
        description = "Total step budget, resumed runs included (default "
          .. engine.DEFAULT_MAX_STEPS
          .. ", max "
          .. engine.HARD_MAX_STEPS
          .. ")",
      },
      step_timeout_secs = {
        type = "integer",
        description = "Time budget per step, tool calls included (default "
          .. engine.DEFAULT_STEP_BUDGET_SECS
          .. "s)",
      },
    },
  }
end

local function handler(input, ctx)
  if not input.script then
    return { llm_output = SCRIPT_REQUIRED_ERR, is_error = true }
  end
  local chunk, compile_err = loadstring(input.script, "workflow")
  if not chunk then
    return { llm_output = SCRIPT_COMPILE_ERR .. compile_err, is_error = true }
  end
  local ok, def = pcall(chunk)
  if not ok then
    return { llm_output = SCRIPT_RETURN_ERR .. tostring(def), is_error = true }
  end

  local opts = {
    call = function(name, params, timeout)
      local value, err = maki.agent.call_tool(ctx, name, params or {}, { timeout = timeout })
      if value == nil then
        error(err, 0)
      end
      return value
    end,
  }
  local script_id = engine.hash(input.script)
  if input.resume then
    local ok_ck, ck = pcall(maki.json.decode, input.resume)
    if not ok_ck or type(ck) ~= "table" then
      return { llm_output = RESUME_DECODE_ERR .. tostring(ck), is_error = true }
    end
    if ck.script ~= script_id then
      return { llm_output = SCRIPT_MISMATCH_ERR, is_error = true }
    end
    if ck.current == nil then
      return { llm_output = RESUME_FINAL_ERR, is_error = true }
    end
    opts.current = ck.current
    opts.state = ck.state
    opts.history = ck.history
  end
  if input.max_steps then
    opts.max_steps = math.min(math.max(input.max_steps, MAX_STEPS_MIN), engine.HARD_MAX_STEPS)
  end
  if input.step_timeout_secs then
    opts.budget_secs = math.max(STEP_TIMEOUT_MIN_SECS, input.step_timeout_secs)
  end

  local run_ok, result = pcall(engine.run, def, opts)
  if not run_ok then
    return { llm_output = tostring(result), is_error = true }
  end

  local lines = { "workflow " .. script_id }
  for _, e in ipairs(result.executed) do
    lines[#lines + 1] = string.format("- %s (%.1fs)", e.step, e.secs)
    for _, msg in ipairs(e.logs) do
      lines[#lines + 1] = "  " .. msg
    end
  end
  if result.done then
    local state_json = engine.stable_encode(result.state)
    return {
      llm_output = table.concat(lines, "\n") .. "\nfinal state: " .. state_json,
    }
  end

  local checkpoint = maki.json.encode(engine.checkpoint(script_id, result))
  return {
    llm_output = table.concat(lines, "\n")
      .. "\naborted: "
      .. result.err
      .. "\ncheckpoint (pass as `resume` with the same script to continue):\n"
      .. CHECKPOINT_FENCE
      .. "\n"
      .. checkpoint
      .. "\n"
      .. CHECKPOINT_FENCE,
    is_error = true,
  }
end

maki.api.register_tool({
  name = "workflow",
  description = DESCRIPTION,
  schema = schema(),
  kind = "execute",
  audiences = { "main", "research_sub", "general_sub" },
  header = function(input)
    local lines = select(2, input.script:gsub("\n", "\n")) + 1
    return lines .. " lines"
  end,
  handler = handler,
})
