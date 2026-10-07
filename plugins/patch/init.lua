local patch_parser = require("patch_parser")
local fuzzy_replace = require("maki.fuzzy_replace")
local shorten_path = require("maki.shorten_path")

local DESCRIPTION = [[Apply a multi-file patch: `*** Begin Patch` (V4A) or unified diff.
Per-file atomic: a file is written only when every hunk in it applied.
Use when `edit` fails to match, or when one call must touch several files.
Prefer `edit` for simple single-file replacements.]]

local function joined(path, workdir)
  return maki.fs.joinpath(workdir, path)
end

local function apply_update(entry, workdir)
  local path = joined(entry.path, workdir)
  local content, err = maki.fs.read(path)
  if not content then
    return nil, err
  end
  for _, change in ipairs(entry.changes) do
    local updated, rerr = fuzzy_replace.replace(content, change.old, change.new, false)
    if not updated then
      return nil, rerr
    end
    content = updated
  end
  local ok, werr = maki.fs.write(path, content)
  if not ok then
    return nil, werr
  end
  return true
end

local function apply_add(entry, workdir)
  local path = joined(entry.path, workdir)
  if maki.fs.read(path) then
    return nil, "file already exists"
  end
  local parent = maki.fs.dirname(path)
  if parent then
    maki.fs.mkdir(parent, { parents = true })
  end
  local ok, err = maki.fs.write(path, table.concat(entry.lines, "\n") .. "\n")
  if not ok then
    return nil, err
  end
  return true
end

local function apply_delete(entry, workdir)
  local path = joined(entry.path, workdir)
  local ok, err = maki.fs.rm(path)
  if not ok then
    return nil, err
  end
  return true
end

local APPLY = { update = apply_update, add = apply_add, delete = apply_delete }
local VERB = { update = "Updated", add = "Added", delete = "Deleted" }

maki.api.register_tool({
  name = "apply_patch",
  kind = "edit",
  description = DESCRIPTION,
  schema = {
    type = "object",
    properties = {
      patch = { type = "string", description = "Patch text: `*** Begin Patch` (V4A) or unified diff", required = true },
      workdir = { type = "string", description = "Base directory for relative paths, e.g. the session cwd", required = true },
    },
  },
  mutable_path = "workdir",
  permission = "fs_write",
  permission_scopes = function(input)
    local parsed = patch_parser.parse(input.patch)
    if not parsed then
      return nil
    end
    local scopes = {}
    for _, entry in ipairs(parsed.files) do
      scopes[#scopes + 1] = joined(entry.path, input.workdir)
    end
    return scopes
  end,

  header = function(input)
    local parsed = patch_parser.parse(input.patch)
    local n = parsed and #parsed.files or "?"
    return "apply_patch " .. tostring(n) .. " files"
  end,

  handler = function(input, ctx)
    local parsed, err = patch_parser.parse(input.patch)
    if not parsed then
      return { llm_output = "error: " .. err, is_error = true }
    end

    local lines = {}
    local failed = 0
    for _, entry in ipairs(parsed.files) do
      local ok, rerr = APPLY[entry.action](entry, input.workdir)
      if ok then
        lines[#lines + 1] = VERB[entry.action] .. " " .. shorten_path(entry.path)
      else
        failed = failed + 1
        lines[#lines + 1] = "Failed " .. entry.path .. ": " .. (rerr or "unknown error")
      end
    end

    return { llm_output = table.concat(lines, "\n"), is_error = failed > 0 }
  end,
})
