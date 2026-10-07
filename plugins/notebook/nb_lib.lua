-- Pure cell helpers for the notebook plugin. No maki API, so the spec can
-- exercise it directly. A "notebook" here is the decoded nbformat table.

local M = {}

M.CELL_TYPES = { code = true, markdown = true, raw = true }
M.ACTIONS = { replace = true, insert_after = true, delete = true }
local SOURCE_PREVIEW_CAP = 300

--- nbformat allows source as a string or an array of lines (with keepends).
function M.source_text(cell)
  local source = cell.source
  if type(source) == "string" then
    return source
  end
  return table.concat(source or {})
end

local function set_source(cell, text)
  cell.source = text
end

local function one_line(text, cap)
  local line = (text:gsub("[\r\n]+", " "))
  if #line > cap then
    line = line:sub(1, cap) .. "…"
  end
  return line
end

--- Numbered, human-readable listing: cell index, type, source, and a capped
--- output preview. This is what the model reads to pick a cell index.
function M.summarize(notebook, max_output_chars)
  local parts = {}
  for i, cell in ipairs(notebook.cells or {}) do
    local source = M.source_text(cell)
    local line = i .. " [" .. (cell.cell_type or "?") .. "]"
    if cell.cell_type == "code" then
      local outputs = cell.outputs or {}
      line = line .. " (" .. #outputs .. " outputs)"
    end
    parts[#parts + 1] = line .. "\n" .. source
    if cell.cell_type == "code" and #(cell.outputs or {}) > 0 then
      local previews = {}
      for _, out in ipairs(cell.outputs) do
        local text = out.text
        if type(text) == "table" then
          text = table.concat(text)
        end
        if type(text) == "string" then
          previews[#previews + 1] = one_line(text, max_output_chars or SOURCE_PREVIEW_CAP)
        end
      end
      if #previews > 0 then
        parts[#parts] = parts[#parts] .. "\noutput: " .. table.concat(previews, " | ")
      end
    end
  end
  return #parts == 0 and "(notebook has no cells)" or table.concat(parts, "\n\n")
end

--- Validate edit input against the notebook. Returns the error message or nil.
function M.check_edit(notebook, opts)
  local action = opts.action or "replace"
  if not M.ACTIONS[action] then
    return "unknown action: " .. tostring(action)
  end
  local count = #(notebook.cells or {})
  if action == "insert_after" then
    if opts.cell > count or opts.cell < 0 then
      return "cell index out of range: " .. tostring(opts.cell) .. " (notebook has " .. count .. " cells)"
    end
    if not M.CELL_TYPES[opts.cell_type or "code"] then
      return "cell_type must be one of: code, markdown, raw"
    end
    return nil
  end
  if opts.cell < 1 or opts.cell > count then
    return "cell index out of range: " .. tostring(opts.cell) .. " (notebook has " .. count .. " cells)"
  end
  if action == "replace" and opts.source == nil then
    return "source is required"
  end
  return nil
end

--- Apply a validated edit in place. `opts` is the same table `check_edit` saw.
function M.apply_edit(notebook, opts)
  local action = opts.action or "replace"
  if action == "delete" then
    table.remove(notebook.cells, opts.cell)
  elseif action == "insert_after" then
    table.insert(notebook.cells, opts.cell + 1, {
      cell_type = opts.cell_type or "code",
      source = opts.source or "",
      metadata = {},
      outputs = (opts.cell_type or "code") == "code" and {} or nil,
    })
  else
    set_source(notebook.cells[opts.cell], opts.source)
  end
  return notebook
end

return M
