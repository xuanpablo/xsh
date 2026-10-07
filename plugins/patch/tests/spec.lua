local parser = require("patch_parser")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

local function files(text)
  local parsed, err = parser.parse(text)
  eq(err, nil, "parse must succeed")
  return parsed.files
end

local V4A = [[*** Begin Patch
*** Update File: src/a.rs
@@
 fn main() {
-    println!("hi");
+    println!("bye");
 }
*** Add File: new.py
+print(1)
+print(2)
*** Delete File: old.txt
*** End Patch
]]

case("empty_patch_is_rejected", function()
  local _, err = parser.parse("")
  eq(err, "patch is empty")
  local _, err2 = parser.parse("   \n")
  eq(err2, "patch is empty")
end)

case("v4a_without_end_is_rejected", function()
  local _, err = parser.parse("*** Begin Patch\n*** Delete File: x\n")
  eq(err, "patch is missing *** End Patch")
end)

case("v4a_parses_update_add_delete", function()
  local fs = files(V4A)
  eq(#fs, 3)

  eq(fs[1].action, "update")
  eq(fs[1].path, "src/a.rs")
  eq(#fs[1].changes, 1)
  eq(table.concat(fs[1].changes[1].old, "\n"), "fn main() {\n    println!(\"hi\");\n}")
  eq(table.concat(fs[1].changes[1].new, "\n"), "fn main() {\n    println!(\"bye\");\n}")

  eq(fs[2].action, "add")
  eq(fs[2].path, "new.py")
  eq(table.concat(fs[2].lines, "\n"), "print(1)\nprint(2)")

  eq(fs[3].action, "delete")
  eq(fs[3].path, "old.txt")
end)

case("v4a_multiple_sections_become_multiple_changes", function()
  local fs = files([[*** Begin Patch
*** Update File: a.txt
@@
-one
+1
@@
-two
+2
*** End Patch
]])
  eq(#fs[1].changes, 2)
  eq(fs[1].changes[1].old[1], "one")
  eq(fs[1].changes[2].old[1], "two")
end)

case("unified_diff_parses_hunks", function()
  local fs = files([[diff --git a/src/a.rs b/src/a.rs
--- a/src/a.rs
+++ b/src/a.rs
@@ -1,3 +1,3 @@ fn main() {
 fn main() {
-    println!("hi");
+    println!("bye");
 }
]])
  eq(#fs, 1)
  eq(fs[1].action, "update")
  eq(fs[1].path, "src/a.rs")
  eq(#fs[1].changes, 1)
  eq(fs[1].changes[1].old[1], "fn main() {")
  eq(fs[1].changes[1].new[2], '    println!("bye");')
end)

case("unified_add_and_delete_files", function()
  local fs = files([[diff --git a/new.py b/new.py
new file mode 100644
--- /dev/null
+++ b/new.py
@@ -0,0 +1,1 @@
+print(1)
diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-goodbye
]])
  eq(fs[1].action, "add")
  eq(fs[1].lines[1], "print(1)")
  eq(fs[2].action, "delete")
  eq(fs[2].path, "old.txt")
end)

case("git_diff_with_slashed_paths_strips_prefixes", function()
  local fs = files([[diff --git a/deep/x.lua b/deep/x.lua
--- a/deep/x.lua
+++ b/deep/x.lua
@@ -1,1 +1,1 @@
-old
+new
]])
  eq(fs[1].path, "deep/x.lua")
end)

case("unrecognized_patch_is_rejected", function()
  local _, err = parser.parse("just some text\n")
  eq(err, "patch contains no file sections")
end)

case("v4a_headers_without_begin_still_parse", function()
  local fs = files("*** Delete File: x.txt\n")
  eq(fs[1].action, "delete")
  eq(fs[1].path, "x.txt")
end)

th.report()
