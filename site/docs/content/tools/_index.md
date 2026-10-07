+++
title = "Tools"
weight = 4
[extra]
group = "Reference"
+++

# Tools

Maki ships with 32 built-in tools in this reference (31 on by default, 1 opt-in via plugin options). Tools marked **opt-in** are off until you enable them under `plugins` in [Configuration](/docs/configuration/).

## File Operations

### `bash` {#bash}

Execute a bash command.
Commands run in the session's working directory (see Environment) by default.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `command` | string | yes |  | The bash command to execute |
| `description` | string | no |  | Short description (3-5 words) of what the command does |
| `sandbox` | string | no |  | Confine the command: reads allowed everywhere, writes only in the working dir |
| `tail` | integer | no |  | Return only the last N lines |
| `timeout` | integer | no | 120 | Timeout in seconds |
| `workdir` | string | no | cwd | Working directory |

### `list` {#list}

List directory contents. Returns entry names sorted alphabetically, directories first with a trailing /.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Absolute path to the directory |

### `read` {#read}

Read a file. Returns contents with line numbers (1-indexed).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | yes | Max number of lines to read. Use 0 to read until end of file (capped at 2000 lines). |
| `offset` | integer | yes | Line number to start from (1-indexed). Use 1 for the first line. |
| `path` | string | yes | Absolute path to the file |

### `write` {#write}

Write content to a file, replacing existing content.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `append` | boolean | no | Add content to the end of the file instead of replacing it |
| `content` | string | yes | The complete file content to write |
| `expected_content_hash` | string | no | sha256 of the file content you last read (the read tool reports it as content_hash). Pass it to make the write fail if the file changed since. |
| `path` | string | yes | Absolute path to the file |

### `edit` {#edit}

Replace an exact string match in a file.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `expected_content_hash` | string | no |  | sha256 of the file content you last read (the read tool reports it as content_hash). Pass it to make the edit fail if the file changed since. |
| `new_string` | string | yes |  | Replacement string |
| `old_string` | string | yes |  | Exact string to find (must match uniquely unless replace_all is true) |
| `path` | string | yes |  | Absolute path to the file |
| `replace_all` | boolean | no | false | Replace all occurrences |

### `multiedit` {#multiedit}

Make multiple find-and-replace edits to a single file atomically.
Prefer this over edit when making multiple changes to the same file.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `edits` | array | yes | Array of edit operations to apply sequentially |
| `expected_content_hash` | string | no | sha256 of the file content you last read (the read tool reports it as content_hash). Pass it to make the edit fail if the file changed since. |
| `path` | string | yes | Absolute path to the file |

### `edit_lines` {#edit_lines}

Edit lines by number. Replaces lines from `start` to `end` (inclusive) with `new_string`. Use empty `new_string` to delete a range. Do not use with the batch tool.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `end` | integer | yes | Last line, inclusive |
| `new_string` | string | yes | Replacement text |
| `path` | string | yes | Absolute path to the file |
| `start` | integer | yes | First line (1-indexed) |

### `insert_lines` <span class="badge badge-optin">opt-in</span> {#insert_lines}

Insert `new_string` after line `line`, or at the top with 0. Only include new lines, never lines already in the file. Do not use with the batch tool.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `line` | integer | yes | Line number to insert after (1-indexed). Use 0 to insert at the top. |
| `new_string` | string | yes | Text to insert |
| `path` | string | yes | Absolute path to the file |

### `glob` {#glob}

Find files by glob pattern.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | string | no | cwd | Directory to search in |
| `pattern` | string | yes |  | Glob pattern (e.g. **/*.rs, src/**/*.ts) |

### `grep` {#grep}

Search file contents using regex.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `context_after` | integer | no |  | Context lines after match |
| `context_before` | integer | no |  | Context lines before match |
| `include` | string | no |  | File glob filter (e.g. *.c) |
| `limit` | integer | no |  | Max match groups to return |
| `path` | string | no | cwd | Directory to search in |
| `pattern` | string | yes |  | Regex pattern |

### `index` {#index}

Return a compact overview of a source file: imports, type definitions, function signatures, and structure with their line numbers surrounded by []. ~70-90% more efficient than reading the full file.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Absolute path to the file |

### `view_image` {#view_image}

View an image file (png, jpeg, gif, webp) so you can actually see it; it is returned as vision input alongside the tool result. Use instead of `read` for images.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Path to the image file |

## Execution & Control

### `batch` {#batch}

Executes multiple independent tool calls concurrently to reduce round-trips.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tool_calls` | array | yes | Array of tool calls to execute in parallel |

### `code_execution` {#code_execution}

Execute Python in a sandbox where every tool is an async function.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `code` | string | yes |  | Python code. Tools return strings, not objects, and you MUST await every call: `result = await read(path='/file', offset=1, limit=0)`. |
| `timeout` | integer | no | 30 | Script execution timeout in seconds |

### `question` {#question}

Use this tool when you need to ask the user questions during execution. This allows you to:
- Gather user preferences or requirements
- Clarify ambiguous instructions
- Get decisions on implementation choices as you work
- Offer choices to the user about what direction to take

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `questions` | array | yes | List of questions to ask the user |

## Agent & Knowledge

### `task` {#task}

Launch an autonomous subagent to perform tasks independently. Best combined with batch.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `description` | string | yes | Short (3-5 words) description of the task |
| `fork_depth` | integer | no | Fork: seed the subagent with the last N messages of this session's transcript (text only) instead of starting blank. Omit to spawn fresh. |
| `model_tier` | string | no | Model tier (optional, omit to use current model, capped at current tier):<br>- "strong" (e.g. Opus): Deep reasoning, complex architecture, subtle bugs, most critical sections. ~5x cost of medium.<br>- "medium" (e.g. Sonnet): Balanced. Refactors, features, multi-file changes.<br>- "weak" (e.g. Haiku): Fast/cheap. Search, summarize, boilerplate, simple edits. |
| `output_schema` | string | no | JSON Schema (object) the subagent's final result must match. When set, the result is returned as a validated JSON string. |
| `prompt` | string | yes | Detailed task prompt for the agent |
| `report` | boolean | no | Require the subagent to call its task_report tool before finishing. The report comes back as a distinct block plus a task id you can resume with `resume`. |
| `resume` | string | no | Task id returned by an earlier report task. Continues that subagent with this prompt instead of spawning a new one. |
| `subagent_type` | string | no | Subagent type: "research" (read-only, default) or "general" (can modify files) |
| `thinking` | string | no | Thinking: off\|adaptive\|minimal\|low\|medium\|high\|xhigh\|max\|int budget. Omit to inherit parent; capped at parent. |

### `todo_write` {#todo_write}

Create or update a structured todo list to track tasks.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `todos` | array | yes | The updated todo list |

### `memory` {#memory}

Persistent, project-scoped scratchpad for learnings, patterns, decisions, and gotchas across sessions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string | yes | - `list [tags]`: tag-grouped index, no bodies.<br>- `read path\|tags`: one body (path) or collated bodies (tags).<br>- `write path tags content`: create or overwrite a note.<br>- `delete path` |
| `content` | string | no | Body for write (frontmatter added automatically). |
| `path` | string | no | Relative path, e.g. 'architecture.md'. |
| `tags` | array | no | snake_case tags. Filter for list/read; assigned on write (defaults to filename stem). |

### `skill` {#skill}

Load a skill that provides instructions and workflows for specific tasks.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | yes | Name of the skill to load |

## Web

### `webfetch` {#webfetch}

Fetch a URL and return its contents.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `format` | string | no |  | Output format: markdown (default), text, or html |
| `timeout` | integer | no | 30, max 120 | Timeout in seconds |
| `url` | string | yes |  | URL to fetch (http:// or https://) |

### `websearch` {#websearch}

Search the web for real-time information using Exa AI.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `num_results` | integer | no | 8 | Number of results to return |
| `query` | string | yes |  | Search query |

## Additional tools

### `apply_patch` {#apply_patch}

Apply a multi-file patch: `*** Begin Patch` (V4A) or unified diff.
Per-file atomic: a file is written only when every hunk in it applied.
Use when `edit` fails to match, or when one call must touch several files.
Prefer `edit` for simple single-file replacements.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `patch` | string | yes | Patch text: `*** Begin Patch` (V4A) or unified diff |
| `workdir` | string | yes | Base directory for relative paths, e.g. the session cwd |

### `context_guard` {#context_guard}

Report how full the context window is. The harness nudges you automatically at the threshold; call this to check earlier.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|

### `doctor` {#doctor}

Check that this project's toolchain is installed and dependencies are present.
Covers node, rust, go, and python projects. With `fix = true`, runs the detected install
commands (npm install, cargo fetch, ...). Run this before starting work in an unfamiliar checkout.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `fix` | boolean | no |  | Run the install commands for any missing dependencies |
| `workdir` | string | no | cwd | Project directory |

### `edit_notebook` {#edit_notebook}

Edit a Jupyter notebook cell: replace its source, insert a new cell, or delete one.
Read the notebook first to get 1-based cell numbers.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | no | One of: "replace" (default), "insert_after", "delete" |
| `cell` | integer | yes | 1-based cell index |
| `cell_type` | string | no | For insert_after: "code" (default), "markdown", "raw" |
| `path` | string | yes | Path to the .ipynb file |
| `source` | string | no | New cell source (replace, insert_after) |

### `fleet` {#fleet}

Run one task prompt against many targets in parallel, one subagent each.
`items` are short target identifiers (file paths, module names, queries) appended to the prompt.
Use for bulk refactors, multi-target research, or repeated audits. For a single task use `task`.
Results come back labeled per item; failed items are marked and do not abort the rest.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `description` | string | yes | Short (3-5 words) description of the fleet run |
| `items` | array | yes | Targets to fan out over |
| `output_schema` | string | no | JSON Schema each subagent's final result must match; results come back as validated JSON |
| `prompt` | string | yes | Task prompt; the target is appended as `Target: <item>` |
| `subagent_type` | string | no | Subagent type for each run: "research" (default) or "general" |

### `git_commit` {#git_commit}

Stage all working tree changes and create a commit.
Do NOT commit secrets. Use git_status and git_diff first to know what you are committing.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` | string | yes |  | Commit message (first line = subject) |
| `workdir` | string | no | cwd | Repo directory |

### `git_diff` {#git_diff}

Show the diff of working tree changes. Set `staged` for the staged diff; `path` narrows to one path.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | string | no |  | Limit the diff to this path |
| `staged` | boolean | no |  | Diff the index against HEAD instead of the working tree |
| `workdir` | string | no | cwd | Repo directory |

### `git_status` {#git_status}

Show branch, upstream drift, and a labeled list of working tree changes. Cheaper and more structured than bash git.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `workdir` | string | no | cwd | Repo directory |

### `read_notebook` {#read_notebook}

Read a Jupyter notebook: numbered cells with their type, source, and an output preview.
Use the cell numbers with `edit_notebook`. Do NOT use `read` on .ipynb files: raw JSON wastes context.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `max_output_chars` | integer | no | 300 | Cap per output preview |
| `path` | string | yes |  | Path to the .ipynb file |

### `spill` {#spill}

Read back a spilled tool output: a result too large for the transcript was saved to .maki/spill/<id> and replaced by its head plus a locator.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | yes | Spill id from the locator line |
| `limit` | integer | no | Max lines to read (0 reads to the end, capped) |
| `offset` | integer | no | First line to read (1-indexed, default 1) |

### `verify` {#verify}

Run the project's tests and get failures back, trimmed to the relevant part.
- Autodetects the runner: justfile `test` recipe, npm test, pytest, cargo test.
- Pass `command` to override, e.g. `just lint` or `pytest tests/test_x.py -q`.
- Prefer this over bash for test runs: the output is failure-focused.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `command` | string | no | autodetect | Test command to run |
| `tail` | integer | no |  | Return only the last N lines |
| `workdir` | string | no | cwd | Working directory |