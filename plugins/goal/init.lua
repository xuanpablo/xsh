-- Durable goals with acceptance checks. Unlike todo_write (per-turn step
-- tracking), goals persist to the state dir, survive compaction, and the
-- agent.stop hook nudges the agent until they are done (bounded by core's
-- 3-continuation cap).

local DIR = "goals"

-- session_id -> goals list; loaded lazily from disk, mutated through store().
local goals = {}
-- Sessions that ran a turn since load; their restores are stale replays.
local live = {}

local DESCRIPTION = [[Create or update the durable goal list for this session.

Use for objectives that must outlive a single turn or compaction, especially
ones with an acceptance check. Send the complete list each time
(replace-all semantics).

Each goal may carry an `acceptance` shell command that proves it is done
(e.g. "just test"). The stop hook keeps nudging the agent until every goal
is completed or cancelled, so only add goals you intend to finish; if you
are blocked, ask the user instead of leaving a goal pending.]]

local function state_path(sid)
  return maki.fs.joinpath(maki.env.state_dir(), DIR, sid .. ".json")
end

local function load(sid)
  if goals[sid] ~= nil then
    return goals[sid]
  end
  local text = maki.fs.read(state_path(sid))
  local items = {}
  if text and text ~= "" then
    local decoded, err = maki.json.decode(text)
    if decoded and type(decoded.goals) == "table" then
      items = decoded.goals
    elseif err then
      maki.log.warn("goal state unreadable: " .. tostring(err))
    end
  end
  goals[sid] = items
  return items
end

local function store(sid, items)
  goals[sid] = items
  local path = state_path(sid)
  if #items == 0 then
    maki.fs.rm(path)
    return
  end
  local encoded, err = maki.json.encode({ goals = items })
  if not encoded then
    maki.log.warn("goal state not saved: " .. tostring(err))
    return
  end
  local parent = maki.fs.dirname(path)
  if not maki.fs.metadata(parent) then
    maki.fs.mkdir(parent, { parents = true })
  end
  maki.fs.write(path, encoded)
end

local function count_unfinished(items)
  local n = 0
  for _, item in ipairs(items) do
    if item.status == "pending" or item.status == "in_progress" then
      n = n + 1
    end
  end
  return n
end

local function sync_hint(items)
  local unfinished = count_unfinished(items)
  if unfinished == 0 then
    maki.ui.set_status_hint(nil)
    return
  end
  maki.ui.set_status_hint({
    { string.format(" %d goal%s left ", unfinished, unfinished == 1 and "" or "s"), "foreground" },
    { "goal", "keybind_key" },
    { " ", "" },
  })
end

local function render(items)
  local lines = {}
  for _, item in ipairs(items) do
    local line = "- [" .. item.status .. "] " .. item.content
    if item.acceptance and item.acceptance ~= "" then
      line = line .. " (acceptance: `" .. item.acceptance .. "`)"
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Use goal for session objectives with acceptance criteria; update after each milestone and when finished. If blocked, ask the user rather than leaving a goal pending.",
})

maki.api.register_tool({
  name = "goal",
  description = DESCRIPTION,
  schema = {
    type = "object",
    required = { "goals" },
    properties = {
      goals = {
        type = "array",
        description = "The updated goal list",
        items = {
          type = "object",
          required = { "content", "status" },
          properties = {
            content = { type = "string", description = "Goal description" },
            status = {
              type = "string",
              enum = { "pending", "in_progress", "completed", "cancelled" },
            },
            acceptance = {
              type = "string",
              description = "Shell command that proves the goal is done (e.g. 'just test')",
            },
          },
        },
      },
    },
  },
  audiences = { "main", "general_sub" },

  header = function(input)
    return string.format("%d goals", #(input.goals or {}))
  end,

  restore = function(input, _output, is_error, ctx)
    local items = input.goals or {}
    local sid = ctx:session_id() or ""
    if not is_error and ctx:restore_reason() == "load" and not live[sid] then
      store(sid, items)
      sync_hint(items)
    end
    if #items == 0 then
      return nil
    end
    local body = maki.ui.buf()
    body:set_lines({ { { render(items), "" } } })
    return body
  end,

  handler = function(input, ctx)
    local items = input.goals or {}
    local sid = ctx:session_id() or ""
    store(sid, items)
    sync_hint(items)
    return #items == 0 and "Goals cleared" or ""
  end,
})

-- The slot receives {reason, last_message, num_turns}; returning
-- {continue = text} maps to Verdict::Replaced and sends text as the next
-- message, bounded by the 3-continuation cap.
maki.api.set_slot("agent.stop", function(_prev, _stop, ctx)
  local sid = ctx and ctx.session_id
  if not sid then
    return nil
  end
  local items = load(sid)
  if count_unfinished(items) == 0 then
    return nil
  end
  return {
    continue = "There are unfinished goals. Verify each acceptance command"
      .. " yourself (run it, read the output), then update the goal list with"
      .. " the goal tool. If you are blocked, ask the user instead of retrying."
      .. "\n\nUnfinished goals:\n" .. render(items),
  }
end)

maki.api.set_slot("agent.compact.before", function(_prev, _value, ctx)
  local sid = ctx and ctx.session_id
  if not sid then
    return nil
  end
  local items = load(sid)
  if #items == 0 then
    return nil
  end
  return { instructions = "Current goals (carry them into the summary):\n" .. render(items) }
end)

maki.api.set_slot("agent.compact.prepare", function(prev, prep)
  local collapse = {}
  for _, i in ipairs(prep.collapse) do
    if prep.results[i].tool ~= "goal" then
      table.insert(collapse, i)
    end
  end
  prep.collapse = collapse
  return prev(prep)
end)

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    live[ev.data.session_id] = true
  end,
})

maki.api.create_autocmd({ "TurnEnd", "SessionReset", "SessionEnd" }, {
  callback = function(ev)
    local sid = ev.data and ev.data.session_id or ""
    live[sid] = nil
    goals[sid] = nil
    if sid ~= "" then
      sync_hint(load(sid))
    end
  end,
})
