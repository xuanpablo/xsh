-- Pure state for the bash_bg plugin: registry of background jobs, bounded
-- line buffers, and the read cursors behind `bash_output` polls. No maki API
-- here, so the spec can exercise it directly.

local M = {}

M.MAX_BUFFER_LINES = 2000

function M.new()
  return { by_id = {}, counter = 0 }
end

function M.next_name(reg)
  reg.counter = reg.counter + 1
  return "bash-bg-" .. reg.counter
end

function M.register(reg, name, command, description)
  local entry = {
    name = name,
    command = command,
    description = description,
    id = nil,
    lines = {},
    total = 0,
    dropped = 0,
    read = 0,
    exit_code = nil,
  }
  reg.by_id[entry] = true
  return entry
end

function M.bind(reg, entry, id)
  entry.id = id
  reg.by_id[id] = entry
  reg.by_id[entry] = nil
end

function M.append(entry, line)
  entry.total = entry.total + 1
  if #entry.lines >= M.MAX_BUFFER_LINES then
    table.remove(entry.lines, 1)
    entry.dropped = entry.dropped + 1
  end
  entry.lines[#entry.lines + 1] = line
end

--- Lines appended since the last drain. Oldest lines that fell out of the
--- bounded buffer before being read come back as the second return value.
function M.drain(entry)
  local window_start = entry.total - #entry.lines + 1
  local first = math.max(entry.read + 1, window_start)
  local skipped = first - entry.read - 1
  local offset = window_start - 1
  local out = {}
  for i = first, entry.total do
    out[#out + 1] = entry.lines[i - offset]
  end
  entry.read = entry.total
  return out, skipped
end

function M.label(entry)
  if entry.description then
    return entry.description .. " [" .. entry.command .. "]"
  end
  return entry.command
end

return M
