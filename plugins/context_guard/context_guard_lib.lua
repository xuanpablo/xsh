-- Pure threshold math and wording for the context_guard plugin. No maki API,
-- so the spec can exercise it directly.

local M = {}

M.DEFAULT_NUDGE_PCT = 80

M.COMPACT_INSTRUCTIONS = table.concat({
  "Keep, in full: the current goal, files edited this session, test failures,",
  "and any error messages being worked on.",
  "Collapse: file contents not touched recently, completed subagent transcripts,",
  "and old tool output. Replace them with one-line summaries.",
}, " ")

function M.pct(context_size, context_window)
  if not context_size or not context_window or context_window <= 0 then
    return 0
  end
  return math.floor(context_size * 100 / context_window)
end

--- Nudge the model once when the crossing happens and the turn just ended.
function M.should_nudge(context_size, context_window, threshold_pct, already_nudged)
  if already_nudged then
    return false
  end
  return M.pct(context_size, context_window) >= (threshold_pct or M.DEFAULT_NUDGE_PCT)
end

M.NUDGE_FMT = [[Context is %d%% full (threshold %d%%). Before going further:
- Record durable state: write findings to a file or maki memory so they survive compaction.
- Stop re-reading large files you have already seen; work from notes.
- Wrap up the current task instead of starting new ones.]]

function M.nudge_message(context_size, context_window, threshold_pct)
  return M.NUDGE_FMT:format(
    M.pct(context_size, context_window),
    threshold_pct or M.DEFAULT_NUDGE_PCT
  )
end

return M
