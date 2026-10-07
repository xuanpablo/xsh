local SPILL_DIR = ".maki/spill"
local ID_PATTERN = "^[A-Za-z0-9%-]+$"
local DEFAULT_MAX_LINES = 400

local DESCRIPTION = [[Read back a spilled tool output: a result too large for the transcript was saved to .maki/spill/<id> and replaced by its head plus a locator.

- The locator line names the id (e.g. `[full output at .maki/spill/abc123 ...]`).
- offset starts at 1; limit=0 reads to the end of the file (capped).]]

local function split_lines(content)
  local lines = {}
  for line in content:gmatch("([^\n]*)\n?") do
    lines[#lines + 1] = line
  end
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

maki.api.register_tool({
  name = "spill",
  kind = "read",
  description = DESCRIPTION,

  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Spill id from the locator line", required = true },
      offset = { type = "integer", description = "First line to read (1-indexed, default 1)" },
      limit = { type = "integer", description = "Max lines to read (0 reads to the end, capped)" },
    },
  },

  handler = function(input)
    local id = input.id
    if not id or not id:match(ID_PATTERN) then
      return {
        llm_output = "error: id must be the name from a spill locator line ([A-Za-z0-9-]+)",
        is_error = true,
      }
    end

    local content, err = maki.fs.read(SPILL_DIR .. "/" .. id)
    if not content then
      return { llm_output = "read error: " .. tostring(err), is_error = true }
    end

    local lines = split_lines(content)
    local total = #lines
    if total == 0 then
      return { llm_output = "empty spill file" }
    end

    local start = math.max(math.floor(input.offset or 1), 1)
    if start > total then
      return {
        llm_output = string.format("error: offset %d is past the end (%d lines)", start, total),
        is_error = true,
      }
    end
    local limit = input.limit or DEFAULT_MAX_LINES
    local max_lines = limit == 0 and DEFAULT_MAX_LINES or math.min(limit, DEFAULT_MAX_LINES)

    local parts = {}
    for i = start, math.min(start + max_lines - 1, total) do
      parts[#parts + 1] = string.format("%d: %s", i, lines[i])
    end
    local shown = #parts
    local llm_output = table.concat(parts, "\n")

    local trunc_start = start + shown
    if trunc_start <= total then
      llm_output = llm_output
        .. string.format("\n\n...\n\nTruncated lines: %d-%d. Use offset=%d to read further.", trunc_start, total, trunc_start)
    end

    return {
      llm_output = llm_output,
      annotation = string.format("%d of %d lines", shown, total),
    }
  end,
})
