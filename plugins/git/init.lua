local git_lib = require("git_lib")
local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")

local OPTS = maki.api.register_options(output_limits.extend({
  timeout_secs = { default = 30, min = 5, desc = "Kill a git command after this many seconds." },
}))

local GIT_MISSING_ERR = "error: git is not available in PATH"
local NOT_A_REPO_HINT = " (is the workdir inside a git repository?)"
local COMMIT_MESSAGE_ERR = "error: message is required"
local NOTHING_TO_COMMIT = "Nothing to commit: the working tree is clean."
local COMMITTED_FMT = "Committed %s: %s"
local MAX_DIFF_BYTES = 50 * 1024

local function git(args, workdir, ctx)
  local argv = { "git", "-c", "core.quotepath=false" }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end
  local id, err = maki.fn.jobstart(argv, { cwd = workdir })
  if not id then
    return nil, err == "git could not start" and GIT_MISSING_ERR or err
  end
  local result = maki.fn.jobwait(id, OPTS.timeout_secs * 1000)
  if not result then
    return nil, "git timed out after " .. OPTS.timeout_secs .. "s"
  end
  if result.exit_code ~= 0 then
    return nil, (result.stderr ~= "" and result.stderr or result.stdout) .. NOT_A_REPO_HINT
  end
  return result.stdout
end

maki.api.register_tool({
  name = "git_status",
  kind = "execute",
  description = "Show branch, upstream drift, and a labeled list of working tree changes. Cheaper and more structured than bash git.",
  schema = {
    type = "object",
    properties = {
      workdir = { type = "string", description = "Repo directory (default: cwd)" },
    },
  },
  header = function(input)
    return "git_status"
  end,

  handler = function(input, ctx)
    local text, err = git({ "status", "--porcelain=v1", "-b" }, input.workdir, ctx)
    if not text then
      return { llm_output = "error: " .. err, is_error = true }
    end
    return { llm_output = git_lib.format_status(git_lib.parse_status(text)) }
  end,
})

maki.api.register_tool({
  name = "git_diff",
  kind = "execute",
  description = "Show the diff of working tree changes. Set `staged` for the staged diff; `path` narrows to one path.",
  schema = {
    type = "object",
    properties = {
      staged = { type = "boolean", description = "Diff the index against HEAD instead of the working tree" },
      path = { type = "string", description = "Limit the diff to this path" },
      workdir = { type = "string", description = "Repo directory (default: cwd)" },
    },
  },
  header = function(input)
    return input.staged and "git_diff (staged)" or "git_diff"
  end,

  handler = function(input, ctx)
    local args = { "diff" }
    if input.staged then
      args[#args + 1] = "--cached"
    end
    if input.path then
      args[#args + 1] = "--"
      args[#args + 1] = input.path
    end
    local text, err = git(args, input.workdir, ctx)
    if not text then
      return { llm_output = "error: " .. err, is_error = true }
    end
    if text == "" then
      return { llm_output = "No changes." }
    end
    local max_lines = math.floor(MAX_DIFF_BYTES / 80)
    return { llm_output = truncate(git_lib.tail_lines(text), max_lines, MAX_DIFF_BYTES) }
  end,
})

maki.api.register_tool({
  name = "git_commit",
  kind = "execute",
  description = [[Stage all working tree changes and create a commit.
Do NOT commit secrets. Use git_status and git_diff first to know what you are committing.]],
  schema = {
    type = "object",
    properties = {
      message = { type = "string", description = "Commit message (first line = subject)", required = true },
      workdir = { type = "string", description = "Repo directory (default: cwd)" },
    },
  },
  permission = "run",
  permission_scopes = function(input)
    if not input.message then
      return nil
    end
    return { "git commit: " .. input.message, force_prompt = true }
  end,
  header = function(input)
    return "git_commit: " .. ((input.message or ""):match("^[^\n]*"))
  end,

  handler = function(input, ctx)
    if not input.message or input.message:match("^%s*$") then
      return { llm_output = COMMIT_MESSAGE_ERR, is_error = true }
    end

    local status, err = git({ "status", "--porcelain=v1" }, input.workdir, ctx)
    if not status then
      return { llm_output = "error: " .. err, is_error = true }
    end
    local parsed = git_lib.parse_status(status)
    if #parsed.files == 0 then
      return { llm_output = NOTHING_TO_COMMIT }
    end

    local staged, stage_err = git({ "add", "-A" }, input.workdir, ctx)
    if not staged then
      return { llm_output = "error: " .. stage_err, is_error = true }
    end

    local committed, commit_err = git({ "commit", "-m", input.message }, input.workdir, ctx)
    if not committed then
      return { llm_output = "error: " .. commit_err, is_error = true }
    end

    local hash = git({ "rev-parse", "--short", "HEAD" }, input.workdir, ctx)
    return { llm_output = COMMITTED_FMT:format(hash or "?", input.message:match("^[^\n]*")) }
  end,
})
