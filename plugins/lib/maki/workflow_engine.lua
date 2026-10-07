-- Bounded interpreter loop for the workflow tool: runs a state machine the
-- model wrote, one step per iteration, with a step budget, a per-step clock,
-- loop detection (the same step twice over the same state aborts) and a
-- checkpoint the caller can resume from. No `maki.*` calls here, so the loop
-- is unit-testable from the plugin spec.

local M = {}

M.DEFAULT_MAX_STEPS = 25
M.DEFAULT_STEP_BUDGET_SECS = 120
M.HARD_MAX_STEPS = 100

M.ERR_NO_STEPS = "script must return a table with a `steps` table of functions"
M.ERR_NO_START = "script must define `start` (a step name) unless resumed"
M.ERR_BAD_STEP = "step `%s` is not a function"
M.ERR_UNKNOWN_STEP = "step `%s` is not defined in `steps`"
M.ERR_NEXT = "step `%s` must return a step name (string) or nil to finish"
M.ERR_MAX_STEPS = "step budget exhausted (%d steps)"
M.ERR_LOOP = "loop detected: step `%s` ran twice with the same state; change the state or the step"
M.ERR_BUDGET = "step `%s` exceeded its %.0fs budget"
M.ERR_STATE = "state must be JSON-encodable: no functions or mixed array/object keys"

local HASH_SEED = 5381
local HASH_MUL = 33
local BITS32 = 0xffffffff
local KEY_SEP = "\0"

local function stable_encode(value)
  local t = type(value)
  if value == nil then
    return "null"
  end
  if t == "boolean" or t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return string.format("%q", value)
  end
  if t ~= "table" then
    error(M.ERR_STATE, 0)
  end
  local n = 0
  local keys = {}
  for k in pairs(value) do
    n = n + 1
    keys[n] = k
  end
  local is_array = #value == n
  if is_array then
    local parts = {}
    for i, v in ipairs(value) do
      parts[i] = stable_encode(v)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then
      return type(a) < type(b)
    end
    return a < b
  end)
  local parts = {}
  for i, k in ipairs(keys) do
    if type(k) ~= "string" then
      error(M.ERR_STATE, 0)
    end
    parts[i] = string.format("%q", k) .. ":" .. stable_encode(value[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.hash(s)
  local h = HASH_SEED
  for i = 1, #s do
    h = bit32.band(h * HASH_MUL + s:byte(i), BITS32)
  end
  return string.format("%08x-%d", h, #s)
end

M.stable_encode = stable_encode

local function abort(err, current, state, history, executed)
  return {
    done = false,
    err = err,
    current = current,
    state = state,
    history = history,
    executed = executed,
  }
end

-- `def` is the script's return value: `{ start = "name", steps = { name = fn } }`.
-- Each step gets `(ctx, state)` where `ctx.call(tool, params)` dispatches a
-- tool call under the remaining step budget, and returns the next step name
-- plus an optional replacement state; `nil` finishes the run. `opts` carries
-- `call(tool, params, timeout_secs)`, `budget_secs`, `max_steps`, `now`, and
-- the resumed `current` / `state` / `history`.
function M.run(def, opts)
  opts = opts or {}
  local now = opts.now or os.clock
  local history = opts.history or {}
  local executed = {}
  if type(def) ~= "table" or type(def.steps) ~= "table" then
    error(M.ERR_NO_STEPS, 0)
  end
  for name, fn in pairs(def.steps) do
    if type(fn) ~= "function" then
      error(M.ERR_BAD_STEP:format(name), 0)
    end
  end
  local current = opts.current
  if current == nil then
    if type(def.start) ~= "string" then
      error(M.ERR_NO_START, 0)
    end
    current = def.start
  end
  local state = opts.state or {}
  local max_steps = opts.max_steps or M.DEFAULT_MAX_STEPS
  local budget = opts.budget_secs or M.DEFAULT_STEP_BUDGET_SECS
  local seen = {}
  for _, h in ipairs(history) do
    seen[h.step .. KEY_SEP .. h.digest] = true
  end

  while type(current) == "string" do
    local step_fn = def.steps[current]
    if not step_fn then
      return abort(M.ERR_UNKNOWN_STEP:format(current), current, state, history, executed)
    end
    local encode_ok, encoded = pcall(stable_encode, state)
    if not encode_ok then
      return abort(encoded, current, state, history, executed)
    end
    local digest = M.hash(encoded)
    local key = current .. KEY_SEP .. digest
    if seen[key] then
      return abort(M.ERR_LOOP:format(current), current, state, history, executed)
    end
    seen[key] = true
    if #history >= max_steps then
      return abort(M.ERR_MAX_STEPS:format(max_steps), current, state, history, executed)
    end
    local t0 = now()
    local logs = {}
    local step_ctx = {
      budget_secs = budget,
      log = function(msg)
        logs[#logs + 1] = tostring(msg)
      end,
      call = function(tool, params)
        return opts.call(tool, params, math.max(1, budget - (now() - t0)))
      end,
    }
    local ok, next_step, new_state = pcall(step_fn, step_ctx, state)
    if not ok then
      return abort(tostring(next_step), current, state, history, executed)
    end
    if next_step ~= nil and type(next_step) ~= "string" then
      return abort(M.ERR_NEXT:format(current), current, state, history, executed)
    end
    local secs = now() - t0
    history[#history + 1] = { step = current, digest = digest, secs = secs }
    executed[#executed + 1] = { step = current, secs = secs, logs = logs }
    if new_state ~= nil then
      state = new_state
    end
    if secs > budget then
      return abort(M.ERR_BUDGET:format(current, budget), next_step, state, history, executed)
    end
    current = next_step
  end

  return { done = true, state = state, history = history, executed = executed }
end

function M.checkpoint(script_id, result)
  return {
    script = script_id,
    current = result.current,
    state = result.state,
    history = result.history,
  }
end

return M
