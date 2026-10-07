local lib = require("verify_lib")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq

case("detect_prefers_justfile_test_recipe", function()
  eq(lib.detect({ justfile = "test:\n\tnextest run\n" }), "just test")
  eq(lib.detect({ [".justfile"] = "lint:\n\techo\n\ntest:\n\techo\n" }), "just test")
end)

case("detect_ignores_justfile_without_test_recipe", function()
  eq(lib.detect({ justfile = "lint:\n\techo\n" }), nil)
end)

case("detect_npm_needs_test_script", function()
  eq(lib.detect({ ["package.json"] = '{"scripts": {"test": "vitest"}}' }), "npm test")
  eq(lib.detect({ ["package.json"] = '{"scripts": {"build": "tsc"}}' }), nil)
end)

case("detect_python_then_rust_order", function()
  eq(lib.detect({ ["pyproject.toml"] = "[tool.pytest]" }), "python -m pytest -q")
  eq(lib.detect({ ["pytest.ini"] = true }), "python -m pytest -q")
  eq(lib.detect({ ["Cargo.toml"] = true }), "cargo test --quiet")
  eq(
    lib.detect({ ["Cargo.toml"] = true, ["pyproject.toml"] = "[tool.pytest]" }),
    "python -m pytest -q"
  )
end)

case("detect_unknown_project", function()
  eq(lib.detect({}), nil)
  eq(lib.detect({ ["go.mod"] = true }), nil)
end)

case("has_failure_matches_common_markers", function()
  eq(lib.has_failure("test result: FAILED. 1 failed"), true)
  eq(lib.has_failure("error[E0308]: mismatched types"), true)
  eq(lib.has_failure("thread 't' panicked at src/main.rs:2"), true)
  eq(lib.has_failure("test result: ok. 5 passed"), false)
end)

case("focus_failures_keeps_context_before_first_failure", function()
  local text = table.concat({
    "line1",
    "line2",
    "line3",
    "line4",
    "error: boom",
    "detail",
  }, "\n")
  local focused = lib.focus_failures(text)
  eq(focused:find("line1", 1, true), nil, "early line must be dropped")
  eq(focused:find("line3", 1, true) ~= nil, true, "context line must survive")
  eq(focused:find("detail", 1, true) ~= nil, true)
  eq(focused:find("^%(earlier output dropped%)"), 1)
end)

case("focus_failures_passes_clean_output_through", function()
  eq(lib.focus_failures("all good\n"), "all good\n")
end)

th.report()
