local state = require("bg_state")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

case("next_name_is_sequential", function()
  local reg = state.new()
  eq(state.next_name(reg), "bash-bg-1")
  eq(state.next_name(reg), "bash-bg-2")
end)

case("register_then_bind_moves_key_from_entry_to_id", function()
  local reg = state.new()
  local entry = state.register(reg, "bash-bg-1", "cargo build", "build")
  eq(reg.by_id[entry], true)
  state.bind(reg, entry, 7)
  eq(reg.by_id[entry], nil)
  eq(reg.by_id[7], entry)
  eq(entry.id, 7)
end)

case("drain_returns_only_new_lines", function()
  local reg = state.new()
  local entry = state.register(reg, "bash-bg-1", "tail -F x", nil)
  state.append(entry, "a")
  state.append(entry, "b")

  local first, skipped = state.drain(entry)
  eq(#first, 2)
  eq(first[1], "a")
  eq(skipped, 0)

  state.append(entry, "c")
  local second = state.drain(entry)
  eq(#second, 1)
  eq(second[1], "c")
end)

case("drain_reports_lines_dropped_before_read", function()
  local reg = state.new()
  local entry = state.register(reg, "bash-bg-1", "server", nil)
  for i = 1, state.MAX_BUFFER_LINES + 5 do
    state.append(entry, "line " .. i)
  end
  local lines, skipped = state.drain(entry)
  eq(#lines, state.MAX_BUFFER_LINES)
  eq(skipped, 5)
  eq(lines[1], "line 6")
  eq(lines[#lines], "line " .. (state.MAX_BUFFER_LINES + 5))
  eq(entry.dropped, 5)
end)

case("buffer_stays_bounded", function()
  local reg = state.new()
  local entry = state.register(reg, "bash-bg-1", "server", nil)
  for i = 1, state.MAX_BUFFER_LINES * 3 do
    state.append(entry, "x" .. i)
  end
  eq(#entry.lines, state.MAX_BUFFER_LINES)
end)

case("label_prefers_description", function()
  local reg = state.new()
  local described = state.register(reg, "a", "npm run dev", "dev server")
  local plain = state.register(reg, "b", "npm run dev", nil)
  eq(state.label(described), "dev server [npm run dev]")
  eq(state.label(plain), "npm run dev")
end)

th.report()
