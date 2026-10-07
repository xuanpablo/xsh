local guard = require("context_guard_lib")

local opts = maki.api.register_options({
  nudge_pct = {
    default = guard.DEFAULT_NUDGE_PCT,
    min = 10,
    desc = "Context fill percentage that triggers the wrap-up nudge.",
  },
  compact_instructions = {
    default = true,
    desc = "Append guard instructions to every compaction summary prompt.",
  },
})

local nudged = false

maki.api.set_slot("agent.user_message", function(prev, msg, ctx)
  nudged = false
  return prev(msg, ctx)
end)

maki.api.register_tool({
  name = "context_guard",
  kind = "read",
  description = "Report how full the context window is. The harness nudges you automatically at the threshold; call this to check earlier.",
  schema = {
    type = "object",
    properties = {},
  },
  header = function(_input)
    return "context_guard"
  end,

  handler = function(_input, ctx)
    local pct = guard.pct(ctx.context_size, ctx.context_window)
    return { llm_output = "Context: " .. pct .. "% of the window used (nudge threshold " .. opts.nudge_pct .. "%)." }
  end,
})

maki.api.set_slot("agent.stop", function(prev, stop, ctx)
  local threshold = opts.nudge_pct
  if not guard.should_nudge(ctx.context_size, ctx.context_window, threshold, nudged) then
    return prev(stop, ctx)
  end
  nudged = true
  local handled = prev(stop, ctx)
  if handled and type(handled) == "table" and handled.continue then
    handled.continue = handled.continue .. "\n\n" .. guard.nudge_message(ctx.context_size, ctx.context_window, threshold)
    return handled
  end
  return { continue = guard.nudge_message(ctx.context_size, ctx.context_window, threshold) }
end)

maki.api.set_slot("agent.compact.before", function(prev, prep, ctx)
  nudged = false
  if not opts.compact_instructions then
    return prev(prep, ctx)
  end
  prep.instructions = (prep.instructions and (prep.instructions .. "\n") or "") .. guard.COMPACT_INSTRUCTIONS
  return prev(prep, ctx)
end)
