local M = {}

local Ui = require("sven.lib.ui")
local util = require("sven.lib.util")
local common_ui = require("sven.buffers.common")

local Diff = common_ui.Diff
local EmptyLine = common_ui.EmptyLine
local text = Ui.text
local col = Ui.col
local row = Ui.row
local map = util.map

-- The widest a bar of `+` and `-` gets in the overview
local MAX_BAR = 40

---@param count number
---@param singular string
---@param plural string
---@return string
local function counted(count, singular, plural)
  return ("%d %s"):format(count, count == 1 and singular or plural)
end

---The line git prints below a diffstat: "3 files changed, 2 insertions(+), 1 deletion(-)"
---@param diffs Diff[]
---@param stats DiffStats|nil Totals. Computed from the diffs when missing
---@return string
function M.summary(diffs, stats)
  if not stats then
    stats = { additions = 0, deletions = 0 }
    for _, diff in ipairs(diffs) do
      stats.additions = stats.additions + diff.stats.additions
      stats.deletions = stats.deletions + diff.stats.deletions
    end
  end

  local parts = { counted(#diffs, "file changed", "files changed") }
  if stats.additions > 0 then
    table.insert(parts, counted(stats.additions, "insertion(+)", "insertions(+)"))
  end
  if stats.deletions > 0 then
    table.insert(parts, counted(stats.deletions, "deletion(-)", "deletions(-)"))
  end

  return table.concat(parts, ", ")
end

---@param diff Diff
---@return string changes What is shown in the count column
---@return string insertions A bar of `+`
---@return string deletions A bar of `-`
local function bars(diff)
  local additions = diff.stats.additions
  local deletions = diff.stats.deletions
  local total = additions + deletions

  if total == 0 then
    if diff.binary then
      return "Bin", "", ""
    elseif diff.props_only or #(diff.props or {}) > 0 then
      return "props", "", ""
    end

    return "0", "", ""
  end

  if total > MAX_BAR then
    if deletions == 0 then
      additions = MAX_BAR
    elseif additions == 0 then
      deletions = MAX_BAR
    else
      -- Scaled down, but a side that has changes keeps at least one character
      local scaled = math.floor(additions * MAX_BAR / total + 0.5)
      scaled = math.min(math.max(scaled, 1), MAX_BAR - 1)
      additions, deletions = scaled, MAX_BAR - scaled
    end
  end

  return tostring(total), ("+"):rep(additions), ("-"):rep(deletions)
end

---One row of the overview: `src/main.c  |     2  +-`. Its `value` option is the file of the diff.
---@param file_padding number Width of the path column
---@return fun(diff: Diff): Component
function M.OverviewFile(file_padding)
  return function(diff)
    local changes, insertions, deletions = bars(diff)

    return row.tag("OverviewFile")({
      text.highlight("SvenFilePath")(util.pad_right(diff.file, file_padding)),
      text("  | "),
      text.highlight("Number")(util.pad_left(changes, 5)),
      text("  "),
      text.highlight("SvenDiffAdditions")(insertions),
      text.highlight("SvenDiffDeletions")(deletions),
    }, { value = diff.file })
  end
end

---The overview of some diffs: one row per file
---@param diffs Diff[]
---@return Component
function M.Overview(diffs)
  local file_padding = util.max_length(map(diffs, function(diff)
    return diff.file
  end))

  return col(map(diffs, M.OverviewFile(file_padding)), { tag = "OverviewFileList" })
end

---@param header string
---@param diffs Diff[]
---@param stats DiffStats|nil
---@return Component[]
function M.DiffView(header, diffs, stats)
  return {
    text.highlight("SvenFloatHeaderHighlight")(header),
    text(M.summary(diffs, stats)),
    M.Overview(diffs),
    EmptyLine(),
    col(map(diffs, Diff), { tag = "DiffList" }),
  }
end

return M
