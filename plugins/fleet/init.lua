local OUTPUT_LIMIT = 20
local DESCRIPTION = [[Run one task prompt against many targets in parallel, one subagent each.
`items` are short target identifiers (file paths, module names, queries) appended to the prompt.
Use for bulk refactors, multi-target research, or repeated audits. For a single task use `task`.
Results come back labeled per item; failed items are marked and do not abort the rest.]]

local ITEM_REQUIRED_ERR = "error: items (array of targets) is required"
local PROMPT_REQUIRED_ERR = "error: prompt is required"
local ITEM_LIMIT_FMT = "error: at most %d items per fleet run"
local ITEM_FMT = "\n## %s\n%s"
local FAILED_FMT = "\n## %s\nFailed: %s"

local opts = maki.api.register_options({
  max_concurrent = { default = 4, min = 1, desc = "Max concurrently running fleet subagents." },
})

local semaphore = maki.async.semaphore(opts.max_concurrent)

maki.api.register_tool({
  name = "fleet",
  kind = "execute",
  description = DESCRIPTION,
  schema = {
    type = "object",
    properties = {
      description = { type = "string", description = "Short (3-5 words) description of the fleet run", required = true },
      prompt = { type = "string", description = "Task prompt; the target is appended as `Target: <item>`", required = true },
      items = { type = "array", items = { type = "string" }, description = "Targets to fan out over", required = true },
      subagent_type = { type = "string", description = 'Subagent type for each run: "research" (default) or "general"' },
      output_schema = {
        description = "JSON Schema each subagent's final result must match; results come back as validated JSON",
      },
    },
  },
  header = function(input)
    return input.description .. " (" .. tostring(#(input.items or {})) .. " targets)"
  end,

  handler = function(input, ctx)
    if not input.prompt then
      return { llm_output = PROMPT_REQUIRED_ERR, is_error = true }
    end
    if type(input.items) ~= "table" or #input.items == 0 then
      return { llm_output = ITEM_REQUIRED_ERR, is_error = true }
    end
    if #input.items > OUTPUT_LIMIT then
      return { llm_output = ITEM_LIMIT_FMT:format(OUTPUT_LIMIT), is_error = true }
    end

    local runs = {}
    for i, item in ipairs(input.items) do
      runs[i] = function()
        local permit = semaphore:acquire()
        local ok, out = pcall(function()
          local value, call_err = maki.agent.call_tool(ctx, "task", {
            description = input.description,
            prompt = input.prompt .. "\n\nTarget: " .. tostring(item),
            subagent_type = input.subagent_type,
            output_schema = input.output_schema,
          })
          if not value then
            error(call_err, 0)
          end
          return value
        end)
        permit:release()
        if not ok then
          error(out, 0)
        end
        return out
      end
    end

    local results = maki.async.gather(runs)
    local parts = {}
    local failed = 0
    for i, result in ipairs(results) do
      local item = tostring(input.items[i])
      if result.ok then
        parts[#parts + 1] = ITEM_FMT:format(item, result.value)
      else
        failed = failed + 1
        parts[#parts + 1] = FAILED_FMT:format(item, result.err)
      end
    end

    return { llm_output = table.concat(parts, "\n"), is_error = failed > 0 }
  end,
})
