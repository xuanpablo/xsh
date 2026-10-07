-- Pure parsing/formatting for the git plugin. No maki API, so the spec can
-- exercise it directly.

local M = {}

M.MAX_BODY_LINES = 200

--- Parse `git status --porcelain=v1 -b`. Returns
--- { branch = "...", ahead = n, behind = n, files = { { x, y, path, orig_path? } } }
function M.parse_status(text)
  local status = { branch = nil, ahead = 0, behind = 0, files = {} }
  for line in text:gmatch("[^\n]+") do
    if line:sub(1, 2) == "##" then
      status.branch = line:match("^## ([^%s%.]+)")
      status.ahead = tonumber(line:match("ahead (%d+)")) or 0
      status.behind = tonumber(line:match("behind (%d+)")) or 0
    elseif line:match("%S") then
      local x, y = line:sub(1, 1), line:sub(2, 2)
      local rest = line:sub(4)
      local sep = rest:find(" -> ", 1, true)
      if sep then
        status.files[#status.files + 1] = { x = x, y = y, path = rest:sub(sep + 4), orig_path = rest:sub(1, sep - 1) }
      else
        status.files[#status.files + 1] = { x = x, y = y, path = rest }
      end
    end
  end
  return status
end

local X_LABELS = {
  M = "modified", A = "added", D = "deleted", R = "renamed",
  C = "copied", U = "unmerged", ["?"] = "untracked", ["!"] = "ignored",
}

function M.label(code)
  return X_LABELS[code] or "changed"
end

function M.format_status(status)
  if not status.branch then
    return "(no branch info)"
  end
  local parts = { "Branch: " .. status.branch }
  if status.ahead > 0 or status.behind > 0 then
    parts[#parts + 1] = string.format("(%d ahead, %d behind upstream)", status.ahead, status.behind)
  end
  if #status.files == 0 then
    parts[#parts + 1] = "Working tree clean."
  else
    for _, file in ipairs(status.files) do
      local label
      if file.x == "?" or file.x == "!" then
        label = M.label(file.x)
      elseif file.y ~= " " then
        label = M.label(file.y) .. " (unstaged)"
      elseif file.x ~= " " then
        label = M.label(file.x) .. " (staged)"
      else
        label = "changed"
      end
      parts[#parts + 1] = label .. ": " .. file.path
    end
  end
  return table.concat(parts, "\n")
end

--- Last MAX_BODY_LINES lines, with a note when something was dropped.
function M.tail_lines(text)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  if #lines <= M.MAX_BODY_LINES then
    return text
  end
  return string.format("(%d earlier lines dropped)\n%s", #lines - M.MAX_BODY_LINES,
    table.concat(lines, "\n", #lines - M.MAX_BODY_LINES + 1, #lines))
end

return M
