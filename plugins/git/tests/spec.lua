local lib = require("git_lib")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

local PORCELAIN = [[## main...origin/main [ahead 2, behind 1]
 M src/a.rs
M  src/b.rs
?? new.txt
R  old.txt -> renamed.txt
]]

case("parse_status_reads_branch_and_drift", function()
  local status = lib.parse_status(PORCELAIN)
  eq(status.branch, "main")
  eq(status.ahead, 2)
  eq(status.behind, 1)
end)

case("parse_status_classifies_files", function()
  local status = lib.parse_status(PORCELAIN)
  eq(#status.files, 4)
  eq(status.files[1].path, "src/a.rs")
  eq(status.files[1].y, "M")
  eq(status.files[2].x, "M")
  eq(status.files[4].path, "renamed.txt")
  eq(status.files[4].orig_path, "old.txt")
end)

case("parse_status_clean_tree", function()
  local status = lib.parse_status("## main\n")
  eq(#status.files, 0)
end)

case("format_status_labels_rows", function()
  local text = lib.format_status(lib.parse_status(PORCELAIN))
  eq(text:find("Branch: main") ~= nil, true)
  eq(text:find("%(2 ahead, 1 behind upstream%)") ~= nil, true)
  eq(text:find("modified %(unstaged%): src/a.rs") ~= nil, true)
  eq(text:find("modified %(staged%): src/b.rs") ~= nil, true)
  eq(text:find("untracked: new.txt") ~= nil, true)
  eq(text:find("renamed %(staged%): renamed%.txt") ~= nil, true)
end)

case("format_status_clean_tree", function()
  local text = lib.format_status(lib.parse_status("## main\n"))
  eq(text:find("Working tree clean") ~= nil, true)
end)

case("tail_lines_keeps_short_output_whole", function()
  eq(lib.tail_lines("a\nb\nc"), "a\nb\nc")
end)

case("tail_lines_drops_oldest_with_note", function()
  local many, expected = {}, {}
  for i = 1, lib.MAX_BODY_LINES + 10 do
    many[i] = "line " .. i
    expected[i] = "line " .. (i + 10)
  end
  local out = lib.tail_lines(table.concat(many, "\n"))
  eq(out:find("^%(10 earlier lines dropped%)") ~= nil, true)
  eq(out:find("line 11") ~= nil, true)
  eq(out:find("line 10\n") ~= nil, false)
end)

th.report()
