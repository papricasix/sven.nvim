local util = require("sven.lib.util")

local Commit = require("sven.buffers.common").CommitEntry
local ChangedPath = require("sven.buffers.revision_view.ui").ChangedPath

local Ui = require("sven.lib.ui")
local text = Ui.text
local col = Ui.col
local row = Ui.row
local map = util.map

local M = {}

---What a row unfolds to: author, date, the whole message, the changed paths and the revisions
---that were merged (when the log was asked for them).
---@param entry SvenLogEntry
---@return Component
function M.Details(entry)
  local rows = {
    row {
      text.highlight("SvenSubtleText")("Author: "),
      text.highlight("SvenGraphAuthor")(entry.author ~= "" and entry.author or "(no author)"),
    },
    row {
      text.highlight("SvenSubtleText")("Date:   "),
      text(entry.author_date),
    },
    text(""),
    col(map(entry.description, text), { highlight = "SvenCommitViewDescription" }),
  }

  if #entry.paths > 0 then
    table.insert(rows, text(""))
    table.insert(rows, col(map(entry.paths, ChangedPath), { tag = "ChangedPaths" }))
  end

  if entry.merged and #entry.merged > 0 then
    table.insert(rows, text(""))
    table.insert(rows, text.highlight("SvenSubtleText")("Merged:"))
    table.insert(
      rows,
      col(map(entry.merged, function(merged)
        return row {
          text.highlight("SvenObjectId")(merged.abbreviated_commit),
          text(" "),
          text.highlight("SvenGraphAuthor")(merged.author),
          text(" "),
          text(merged.subject),
        }
      end))
    )
  end

  return col.tag("Details").padding_left(#entry.abbreviated_commit + 1)(rows)
end

---One revision: a row (`r42 subject`, with author and date at the right edge) that unfolds to
---its details.
---@param entry SvenLogEntry
---@return Component
function M.Entry(entry)
  local component = Commit(entry, {}, {})
  component:append(M.Details(entry))
  component.options.foldable = true
  component.options.folded = true

  return component
end

---@param entries SvenLogEntry[]
---@param has_more boolean Whether there is older history to load
---@return Component[]
function M.View(entries, has_more)
  local view = map(entries, M.Entry)

  -- The header floats above the first line
  table.insert(view, 1, col { row { text("") } })

  if #entries == 0 then
    table.insert(view, text.highlight("SvenSubtleText")("No revisions"))
  end

  if has_more then
    table.insert(
      view,
      col {
        row {
          text.highlight("SvenGraphBoldBlue")("Type"),
          text.highlight("SvenGraphBoldCyan")(" + "),
          text.highlight("SvenGraphBoldBlue")("to show more history"),
        },
      }
    )
  end

  return view
end

return M
