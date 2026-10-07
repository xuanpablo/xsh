local engine = require("workflow_engine")

local failures = {}

local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    table.insert(failures, name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "") .. "\nexpected: " .. tostring(expected) .. "\n  actual: " .. tostring(actual))
  end
end

local function step_names(result)
  local names = {}
  for i, e in ipairs(result.executed) do
    names[i] = e.step
  end
  return table.concat(names, ",")
end

-- A call recorder whose fake clock only moves when `call` says so, so budget
-- assertions never depend on real timing.
local function fake_env(overrides)
  local env = { t = 0, calls = {} }
  local e = overrides or {}
  env.now = function()
    return env.t
  end
  env.call = function(name, params, timeout)
    env.calls[#env.calls + 1] = { name = name, params = params, timeout = timeout }
    env.t = env.t + (e.call_secs or 0)
    return "out:" .. name
  end
  return env
end

local chain = {
  start = "a",
  steps = {
    a = function(_, state)
      return "b", { n = state.n + 1 }
    end,
    b = function(_, state)
      return nil, { n = state.n + 1 }
    end,
  },
}

case("runs_steps_in_order_and_finishes", function()
  local result = engine.run(chain, fake_env())
  eq(result.done, true, "should finish")
  eq(step_names(result), "a,b", "step order")
  eq(engine.stable_encode(result.state), [[{"n":2}]], "final state")
end)

case("loop_detection_aborts_on_repeat", function()
  local ping = {
    start = "ping",
    steps = {
      ping = function()
        return "ping", {}
      end,
    },
  }
  local result = engine.run(ping, fake_env())
  eq(result.done, false, "should abort")
  eq(result.err:find(engine.ERR_LOOP:format("ping"), 1, true) ~= nil, true, "loop error")
  eq(result.current, "ping", "checkpoint restarts the looped step")
end)

case("different_state_allows_same_step_twice", function()
  local counter = {
    start = "inc",
    steps = {
      inc = function(_, state)
        if state.n >= 3 then
          return nil, state
        end
        return "inc", { n = state.n + 1 }
      end,
    },
  }
  local result = engine.run(counter, { state = { n = 0 }, now = fake_env().now, call = fake_env().call })
  eq(result.done, true, "should finish")
  eq(step_names(result), "inc,inc,inc,inc", "one visit per state")
end)

case("max_steps_aborts_with_checkpoint", function()
  local result = engine.run(chain, { max_steps = 1, now = fake_env().now, call = fake_env().call })
  eq(result.done, false, "should abort")
  eq(result.err, engine.ERR_MAX_STEPS:format(1), "budget error")
  eq(result.current, "b", "checkpoint holds the unrun step")
  eq(#result.history, 1, "one step recorded")
end)

case("resume_continues_from_checkpoint", function()
  local env = fake_env()
  local first = engine.run(chain, { max_steps = 1, now = env.now, call = env.call })
  local second = engine.run(chain, {
    current = first.current,
    state = first.state,
    history = first.history,
    max_steps = 2,
    now = env.now,
    call = env.call,
  })
  eq(second.done, true, "should finish")
  eq(second.executed[1].step, "b", "only the remaining step ran")
  eq(#second.history, 2, "history carried over")
end)

case("step_budget_aborts_after_the_step", function()
  local env = fake_env({ call_secs = 10 })
  local slow = {
    start = "slow",
    steps = {
      slow = function(sctx)
        sctx:call("read", {})
        return nil, {}
      end,
    },
  }
  local result = engine.run(slow, { budget_secs = 5, now = env.now, call = env.call })
  eq(result.done, false, "should abort")
  eq(result.err, engine.ERR_BUDGET:format("slow", 5), "budget error")
  eq(#result.history, 1, "the slow step is recorded, not rerun on resume")
end)

case("call_gets_remaining_budget_and_at_least_a_second", function()
  local env = fake_env({ call_secs = 8 })
  local calls = {
    start = "go",
    steps = {
      go = function(sctx)
        sctx:call("read", {})
        sctx:call("read", {})
      end,
    },
  }
  engine.run(calls, { budget_secs = 10, now = env.now, call = env.call })
  eq(env.calls[1].timeout, 10, "first call gets the full budget")
  eq(env.calls[2].timeout, 2, "second call gets the remainder")
  eq(#env.calls, 2, "calls recorded")
end)

case("unknown_step_aborts", function()
  local bad = { start = "missing", steps = { other = function() end } }
  local result = engine.run(bad, fake_env())
  eq(result.err, engine.ERR_UNKNOWN_STEP:format("missing"), "unknown step error")
end)

case("step_error_aborts_with_restartable_checkpoint", function()
  local boom = {
    start = "boom",
    steps = {
      boom = function()
        error("kaboom", 0)
      end,
    },
  }
  local result = engine.run(boom, fake_env())
  eq(result.err, "kaboom", "error propagated")
  eq(result.current, "boom", "checkpoint restarts the failed step")
  eq(#result.history, 0, "failed step not recorded")
end)

case("malformed_definitions_are_rejected", function()
  local ok, err = pcall(engine.run, { steps = {} }, fake_env())
  eq(ok, false, "missing start rejected")
  eq(err, engine.ERR_NO_START, "start error")
  ok = pcall(engine.run, { steps = { a = 1 }, start = "a" }, fake_env())
  eq(ok, false, "non-function step rejected")
  ok, err = pcall(engine.run, "nope", fake_env())
  eq(ok, false, "non-table def rejected")
  eq(err, engine.ERR_NO_STEPS, "steps error")
end)

case("non_string_next_step_is_rejected", function()
  local bad = {
    start = "a",
    steps = {
      a = function()
        return 42
      end,
    },
  }
  local result = engine.run(bad, fake_env())
  eq(result.err, engine.ERR_NEXT:format("a"), "next-step error")
end)

case("unencodable_state_aborts_instead_of_corrupting_history", function()
  local bad = {
    start = "a",
    steps = {
      a = function()
        return nil, { fn = function() end }
      end,
    },
  }
  local result = engine.run({ start = "a", steps = bad.steps }, fake_env())
  eq(result.done, false, "should abort")
  eq(result.err, engine.ERR_STATE, "state error")
end)

case("stable_encode_is_key_order_independent", function()
  local a, b = {}, {}
  a.x, a.y, a.n = 1, "s", { true }
  b.y, b.n, b.x = "s", { true }, 1
  eq(engine.stable_encode(a), engine.stable_encode(b), "same value, different insertion order")
  eq(engine.stable_encode({ b = 1, a = { 2, 3 } }), [[{"a":[2,3],"b":1}]], "sorted object")
  eq(engine.stable_encode({}), "[]", "empty table is an array")
end)

case("hash_separates_different_inputs", function()
  eq(engine.hash("aa") ~= engine.hash("ab"), true, "different bytes")
  eq(engine.hash("ab") ~= engine.hash("abab"), true, "different length")
end)

case("checkpoint_carries_identity_and_progress", function()
  local result = engine.run(chain, { max_steps = 1, now = fake_env().now, call = fake_env().call })
  local ck = engine.checkpoint("sid", result)
  eq(ck.script, "sid", "script id")
  eq(ck.current, "b", "current step")
  eq(#ck.history, 1, "history")
end)

if #failures > 0 then
  error(#failures .. " case(s) failed:\n\n" .. table.concat(failures, "\n\n"))
end
