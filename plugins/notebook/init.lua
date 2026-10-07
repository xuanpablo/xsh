local nb_lib = require("nb_lib")

local READ_ERR_PREFIX = "error: "
local NOT_NOTEBOOK_ERR = "error: not a notebook (.ipynb) file"
local BAD_NOTEBOOK_ERR = "error: file is not valid notebook JSON"
local INDEX_REQUIRED_ERR = "error: cell (1-based index) is required"
local PATH_REQUIRED_ERR = "error: path is required"
local WROTE_FMT = "Wrote %s (cell %d %s)."
local DEFAULT_OUTPUT_CHARS = 300

local function is_ipynb(path)
  return path:match("%.ipynb$") ~= nil
end

local function load(path)
  local content, err = maki.fs.read(path)
  if not content then
    return nil, err
  end
  local notebook, decode_err = maki.json.decode(content)
  if not notebook then
    return nil, decode_err
  end
  if type(notebook) ~= "table" or type(notebook.cells) ~= "table" then
    return nil, BAD_NOTEBOOK_ERR
  end
  return notebook
end

maki.api.register_tool({
  name = "read_notebook",
  kind = "read",
  description = [[Read a Jupyter notebook: numbered cells with their type, source, and an output preview.
Use the cell numbers with `edit_notebook`. Do NOT use `read` on .ipynb files: raw JSON wastes context.]],
  schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Path to the .ipynb file", required = true },
      max_output_chars = { type = "integer", description = "Cap per output preview (default 300)" },
    },
  },
  header = function(input)
    return input.path
  end,

  handler = function(input)
    if not input.path then
      return { llm_output = PATH_REQUIRED_ERR, is_error = true }
    end
    if not is_ipynb(input.path) then
      return { llm_output = NOT_NOTEBOOK_ERR, is_error = true }
    end

    local notebook, err = load(input.path)
    if not notebook then
      return { llm_output = READ_ERR_PREFIX .. err, is_error = true }
    end
    return { llm_output = nb_lib.summarize(notebook, input.max_output_chars or DEFAULT_OUTPUT_CHARS) }
  end,
})

maki.api.register_tool({
  name = "edit_notebook",
  kind = "edit",
  description = [[Edit a Jupyter notebook cell: replace its source, insert a new cell, or delete one.
Read the notebook first to get 1-based cell numbers.]],
  schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Path to the .ipynb file", required = true },
      cell = { type = "integer", description = "1-based cell index", required = true },
      action = { type = "string", description = 'One of: "replace" (default), "insert_after", "delete"' },
      source = { type = "string", description = "New cell source (replace, insert_after)" },
      cell_type = { type = "string", description = 'For insert_after: "code" (default), "markdown", "raw"' },
    },
  },
  permission = "fs_write",
  mutable_path = "path",
  permission_scopes = "path",
  header = function(input)
    return (input.action or "replace") .. " cell " .. tostring(input.cell) .. " in " .. input.path
  end,

  handler = function(input)
    if not input.path then
      return { llm_output = PATH_REQUIRED_ERR, is_error = true }
    end
    if not input.cell then
      return { llm_output = INDEX_REQUIRED_ERR, is_error = true }
    end
    if not is_ipynb(input.path) then
      return { llm_output = NOT_NOTEBOOK_ERR, is_error = true }
    end

    local notebook, err = load(input.path)
    if not notebook then
      return { llm_output = READ_ERR_PREFIX .. err, is_error = true }
    end

    local invalid = nb_lib.check_edit(notebook, input)
    if invalid then
      return { llm_output = "error: " .. invalid, is_error = true }
    end

    nb_lib.apply_edit(notebook, input)
    local encoded, encode_err = maki.json.encode(notebook)
    if not encoded then
      return { llm_output = "error: " .. encode_err, is_error = true }
    end
    local ok, write_err = maki.fs.write(input.path, encoded)
    if not ok then
      return { llm_output = "error: " .. write_err, is_error = true }
    end
    return {
      llm_output = WROTE_FMT:format(input.path, input.cell, input.action or "replace"),
    }
  end,
})
