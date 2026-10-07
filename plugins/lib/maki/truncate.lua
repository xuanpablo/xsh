local OMITTED_FMT = "[omitted %d lines]"
local TRUNCATED_BYTES_FMT = "[truncated %d bytes]"

local function split_lines(text)
  local lines = {}
  for line in text:gmatch("([^\n]*)\n?") do
    lines[#lines + 1] = line
  end
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

-- Head + tail retention: the line budget splits between the two ends and a
-- marker line names what was dropped, so a truncated output always says so.
local function truncate(text, max_lines, max_bytes)
  local lines = split_lines(text)
  if #lines <= max_lines and #text <= max_bytes then
    return text
  end

  local head_budget = math.max(math.floor(max_lines / 2), 1)
  local head, head_bytes = {}, 0
  for _, line in ipairs(lines) do
    if #head >= head_budget or head_bytes + #line + 1 > max_bytes then
      break
    end
    head[#head + 1] = line
    head_bytes = head_bytes + #line + 1
  end
  if #head == 0 then
    local cut = max_bytes
    while cut > 0 and lines[1]:find("^[\128-\191]", cut + 1) do
      cut = cut - 1
    end
    return lines[1]:sub(1, cut) .. "\n\n" .. string.format(TRUNCATED_BYTES_FMT, #text - cut)
  end

  local tail, tail_bytes = {}, 0
  local tail_budget = max_lines - #head
  local byte_budget = max_bytes - head_bytes
  for i = #lines, #head + 1, -1 do
    if #tail >= tail_budget or tail_bytes + #lines[i] + 1 > byte_budget then
      break
    end
    tail[#tail + 1] = lines[i]
    tail_bytes = tail_bytes + #lines[i] + 1
  end
  for i = 1, math.floor(#tail / 2) do
    tail[i], tail[#tail - i + 1] = tail[#tail - i + 1], tail[i]
  end

  local parts = { table.concat(head, "\n") }
  local omitted = #lines - #head - #tail
  if omitted > 0 then
    parts[#parts + 1] = string.format(OMITTED_FMT, omitted)
  end
  if #tail > 0 then
    parts[#parts + 1] = table.concat(tail, "\n")
  end
  return table.concat(parts, "\n")
end

return truncate
