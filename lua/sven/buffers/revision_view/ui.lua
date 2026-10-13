local M = {}

local Ui = require("sven.lib.ui")
local util = require("sven.lib.util")
local common_ui = require("sven.buffers.common")
local diff_ui = require("sven.buffers.diff.ui")

local Diff = common_ui.Diff
local text = Ui.text
local col = Ui.col
local row = Ui.row
local map = util.map

local ACTION_HIGHLIGHTS = {
  M = "SvenChangeModified",
  A = "SvenChangeAdded",
  D = "SvenChangeDeleted",
  R = "SvenChangeReplaced",
}

---@param revision string|number
---@return Component
function M.Title(revision)
  return text.line_hl("SvenCommitViewHeader")("Revision " .. tostring(revision))
end

---@param entry SvenLogEntry
---@return Component
function M.RevisionHeader(entry)
  local date = entry.author_date
  if entry.rel_date and vim.trim(entry.rel_date) ~= "" then
    date = ("%s (%s)"):format(date, vim.trim(entry.rel_date))
  end

  return col {
    M.Title(entry.revision),
    row {
      text.highlight("SvenSubtleText")("Author:     "),
      text(entry.author ~= "" and entry.author or "(no author)"),
    },
    row { text.highlight("SvenSubtleText")("Date:       "), text(date) },
  }
end

---One changed path of the revision: `M /trunk/src/main.c`, `A /branches/x (from /trunk:41)`.
---Its `value` option is the path.
---@param path SvenRevisionViewPath
---@return Component
function M.ChangedPath(path)
  local copied = nil
  if path.copyfrom_path then
    copied =
      text.highlight("SvenSubtleText")((" (from %s:%s)"):format(path.copyfrom_path, path.copyfrom_rev or "?"))
  end

  return row.tag("ChangedPath")({
    text.highlight(ACTION_HIGHLIGHTS[path.action] or "SvenChangeModified")(path.action),
    text(" "),
    text.highlight("SvenFilePath")(path.path),
    copied,
  }, { value = path })
end

---@class SvenRevisionViewPath: SvenLogPath
---@field file string The name the diff of this path goes by: its path in the working copy, or `^/path` when it is outside

---@class SvenRevisionViewState
---@field revision string|number
---@field loading boolean
---@field error string[]|nil Why the revision could not be loaded
---@field entry SvenLogEntry|nil
---@field paths SvenRevisionViewPath[]
---@field diffs Diff[]
---@field notes string[] Remarks to show above the diffs

---@param state SvenRevisionViewState
---@return Component[]
function M.RevisionView(state)
  if state.loading then
    return {
      M.Title(state.revision),
      text(""),
      text.highlight("SvenSubtleText")("Loading..."),
    }
  end

  local entry = state.entry
  if not entry then
    return {
      M.Title(state.revision),
      text(""),
      col(map(state.error or { "Unable to load the revision" }, function(line)
        return text.highlight("SvenSubtleText")(line)
      end)),
    }
  end

  local view = {
    M.RevisionHeader(entry),
    text(""),
    col(map(entry.description, text), { highlight = "SvenCommitViewDescription", tag = "Description" }),
    text(""),
    text(diff_ui.summary(state.diffs)),
    col(map(state.paths, M.ChangedPath), { tag = "OverviewFileList" }),
    text(""),
  }

  if #state.notes > 0 then
    table.insert(
      view,
      col(map(state.notes, function(line)
        return text.highlight("SvenSubtleText")(line)
      end))
    )
    table.insert(view, text(""))
  end

  table.insert(view, col(map(state.diffs, Diff), { tag = "DiffList" }))

  return view
end

return M
