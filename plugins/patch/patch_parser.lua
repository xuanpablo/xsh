-- Pure parser for the patch plugin: turns V4A (`*** Begin Patch`) or unified
-- diff text into per-file entries. No maki API, so the spec can exercise it
-- directly.
--
-- An entry is:
--   { action = "update", path = ..., changes = { { old = ..., new = ... } } }
--   { action = "add",    path = ..., lines  = { ... } }
--   { action = "delete", path = ... }
--
-- `changes` reuse fuzzy_replace's shape: each `old` block is matched against
-- the file and swapped for `new`, so context lines and forgiveness come free.

local M = {}

local V4A_UPDATE = "^%*%*%* Update File:%s*(.+)$"
local V4A_ADD = "^%*%*%* Add File:%s*(.+)$"
local V4A_DELETE = "^%*%*%* Delete File:%s*(.+)$"
local V4A_SECTION = "^@@"
local UNIFIED_HEADER = "^diff %-%-git "
local UNIFIED_MINUS = "^%-%-%- %S+"
local UNIFIED_HUNK = "^@@ %-%d+"
local NO_NEWLINE = "^\\ No newline"

local EMPTY_PATCH_ERR = "patch is empty"
local UNCLOSED_PATCH_ERR = "patch is missing *** End Patch"
local NO_FILES_ERR = "patch contains no file sections"
local ORPHAN_LINE_ERR = "patch lines before any file header"

local function split_lines(text)
  local lines = {}
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then
      if #text >= pos then
        lines[#lines + 1] = text:sub(pos)
      end
      return lines
    end
    lines[#lines + 1] = text:sub(pos, nl - 1)
    pos = nl + 1
  end
end

local function new_file(action, path)
  return { action = action, path = path, changes = {}, lines = nil }
end

--- V4A body: everything between Begin/End Patch. `@@` starts a new change
--- section; blank lines count as context.
local function parse_v4a(lines)
  local files = {}
  local current
  local change

  local function start_change()
    change = { old = {}, new = {} }
    current.changes[#current.changes + 1] = change
  end

  for _, line in ipairs(lines) do
    local path = line:match(V4A_UPDATE)
    local add_path = line:match(V4A_ADD)
    local delete_path = line:match(V4A_DELETE)
    if path then
      current = new_file("update", path)
      files[#files + 1] = current
      change = nil
    elseif add_path then
      current = new_file("add", add_path)
      current.lines = {}
      files[#files + 1] = current
      change = nil
    elseif delete_path then
      current = new_file("delete", delete_path)
      files[#files + 1] = current
      change = nil
    elseif not current then
      if line:match("%S") then
        return nil, ORPHAN_LINE_ERR
      end
    elseif line:match(V4A_SECTION) then
      start_change()
    elseif current.action == "add" then
      local content = line:match("^%+(.*)$")
      if content then
        current.lines[#current.lines + 1] = content
      end
    elseif current.action == "delete" then
      -- trailing lines after a delete header carry no meaning
    else
      if not change then
        start_change()
      end
      local prefix = line:sub(1, 1)
      local rest = line:sub(2)
      if prefix == "-" then
        change.old[#change.old + 1] = rest
      elseif prefix == "+" then
        change.new[#change.new + 1] = rest
      else
        -- ' ' context, or a bare line the model forgot to prefix: either way
        -- it sits on both sides.
        change.old[#change.old + 1] = rest
        change.new[#change.new + 1] = rest
      end
    end
  end

  return files
end

local function strip_unified_path(path)
  return (path:gsub("^[ab]/", ""))
end

--- Unified diff body. Hunks order the changes; the line numbers are ignored
--- because fuzzy_replace locates blocks by content.
local function parse_unified(lines)
  local files = {}
  local current
  local change

  for _, line in ipairs(lines) do
    if line:match(UNIFIED_HEADER) then
      current = new_file("update", "?")
      files[#files + 1] = current
      change = nil
    elseif line:match(UNIFIED_MINUS) then
      local path = strip_unified_path(line:sub(5))
      if path == "/dev/null" then
        current.action = "add"
        current.lines = {}
      else
        current.path = path
      end
    elseif line:match("^+++ %S+") then
      local path = strip_unified_path(line:sub(5))
      if path == "/dev/null" then
        current.action = "delete"
      else
        current.path = path
      end
    elseif not current then
      if line:match("%S") and not line:match("^index ") and not line:match("^new file")
        and not line:match("^deleted file") and not line:match("^mode ") then
        return nil, ORPHAN_LINE_ERR
      end
    elseif line:match(UNIFIED_HUNK) then
      change = { old = {}, new = {} }
      current.changes[#current.changes + 1] = change
    elseif line:match(NO_NEWLINE) then
      -- information only; fuzzy_replace works on content, not byte streams
    elseif current.action == "add" then
      local content = line:match("^%+(.*)$")
      if content then
        current.lines[#current.lines + 1] = content
      end
    elseif current.action ~= "delete" and change then
      local prefix = line:sub(1, 1)
      local rest = line:sub(2)
      if prefix == "-" then
        change.old[#change.old + 1] = rest
      elseif prefix == "+" then
        change.new[#change.new + 1] = rest
      elseif prefix == " " or line == "" then
        change.old[#change.old + 1] = rest
        change.new[#change.new + 1] = rest
      end
    end
  end

  return files
end

function M.parse(text)
  if not text or text:match("^%s*$") then
    return nil, EMPTY_PATCH_ERR
  end

  local body = text
  local parser
  if text:match("%*%*%* Begin Patch") then
    if not text:match("%*%*%* End Patch") then
      return nil, UNCLOSED_PATCH_ERR
    end
    body = text:gsub("%*%*%* Begin Patch", ""):gsub("%*%*%* End Patch", "")
    parser = parse_v4a
  elseif text:match(UNIFIED_HEADER) or text:match(UNIFIED_MINUS) then
    parser = parse_unified
  elseif text:match(V4A_UPDATE) or text:match(V4A_ADD) or text:match(V4A_DELETE) then
    parser = parse_v4a
  else
    return nil, NO_FILES_ERR
  end

  local files, err = parser(split_lines(body))
  if not files then
    return nil, err
  end
  if #files == 0 then
    return nil, NO_FILES_ERR
  end
  return { files = files }
end

return M
