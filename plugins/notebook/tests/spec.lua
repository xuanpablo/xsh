local lib = require("nb_lib")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

local function notebook()
  return {
    cells = {
      { cell_type = "markdown", source = "# Title" },
      { cell_type = "code", source = { "print(1)\n", "print(2)\n" }, outputs = {} },
    },
  }
end

case("source_text_handles_string_and_lines", function()
  eq(lib.source_text({ source = "a\nb" }), "a\nb")
  eq(lib.source_text({ source = { "a\n", "b" } }), "a\nb")
  eq(lib.source_text({ source = {} }), "")
end)

case("summarize_numbers_cells_and_previews_outputs", function()
  local nb = notebook()
  nb.cells[2].outputs = { { text = "1\n2\n" } }
  local text = lib.summarize(nb)
  eq(text:find("^1 %[markdown%]"), 1)
  eq(text:find("2 %[code%] %(1 outputs%)") ~= nil, true)
  eq(text:find("output: 1 2") ~= nil, true)
end)

case("summarize_caps_output_preview", function()
  local nb = { cells = { { cell_type = "code", source = "x", outputs = { { text = string.rep("a", 400) } } } } }
  local text = lib.summarize(nb, 10)
  local preview = text:match("output: (.*)$")
  eq(#preview <= 14, true, "preview must be capped (10 chars + ellipsis bytes)")
  eq(preview:find("…") ~= nil, true)
end)

case("check_edit_rejects_bad_index_and_action", function()
  local nb = notebook()
  eq(lib.check_edit(nb, { cell = 5, source = "x" }):find("out of range") ~= nil, true)
  eq(lib.check_edit(nb, { cell = 1, action = "frobnicate" }):find("unknown action") ~= nil, true)
  eq(lib.check_edit(nb, { cell = 1, source = "x" }), nil, "replace with source is fine")
  eq(lib.check_edit(nb, { cell = 1, action = "replace" }), "source is required")
end)

case("check_edit_insert_allows_append_and_validates_type", function()
  local nb = notebook()
  eq(lib.check_edit(nb, { cell = 2, action = "insert_after", source = "x" }), nil)
  eq(lib.check_edit(nb, { cell = 0, action = "insert_after", source = "x" }), nil)
  eq(lib.check_edit(nb, { cell = 3, action = "insert_after", source = "x" }):find("out of range") ~= nil, true)
  eq(
    lib.check_edit(nb, { cell = 1, action = "insert_after", source = "x", cell_type = "plot" }):find("cell_type")
      ~= nil,
    true
  )
end)

case("apply_edit_replaces_inserts_deletes", function()
  local nb = notebook()
  lib.apply_edit(nb, { cell = 1, source = "new" })
  eq(lib.source_text(nb.cells[1]), "new")

  lib.apply_edit(nb, { cell = 2, action = "insert_after", source = "tail", cell_type = "markdown" })
  eq(#nb.cells, 3)
  eq(nb.cells[3].cell_type, "markdown")
  eq(lib.source_text(nb.cells[3]), "tail")

  lib.apply_edit(nb, { cell = 1, action = "delete" })
  eq(#nb.cells, 2)
  eq(nb.cells[1].cell_type, "code")
end)

th.report()
