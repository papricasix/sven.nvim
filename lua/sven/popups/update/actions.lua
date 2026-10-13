local svn = require("sven.lib.svn")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local event = require("sven.lib.event")

local M = {}

-- What svn did to an item, by the letter it prints, in the order the summary lists them
local OUTCOMES = {
  { "U", "updated" },
  { "A", "added" },
  { "D", "deleted" },
  { "R", "replaced" },
  { "G", "merged" },
  { "E", "existed" },
  { "C", "conflicted" },
}

---@param conflict SvenUpdateConflict
---@return string
local function conflict_kinds(conflict)
  local kinds = {}
  if conflict.text then
    table.insert(kinds, "text")
  end
  if conflict.prop then
    table.insert(kinds, "property")
  end
  if conflict.tree then
    table.insert(kinds, "tree")
  end

  return table.concat(kinds, ", ")
end

---Describes the outcome of an update in a few lines: the revision, how many items were touched
---in which way, and the conflicts that are left.
---@param summary SvenUpdateSummary
---@return string message
---@return integer level `vim.log.levels`: a warning when conflicts are left
function M.describe(summary)
  local counts = {}
  for _, outcome in ipairs(OUTCOMES) do
    local letter, word = unpack(outcome)
    if summary.counts[letter] then
      table.insert(counts, ("%d %s"):format(summary.counts[letter], word))
    end
  end

  local skipped = 0
  for _, line in ipairs(summary.result and summary.result.stdout or {}) do
    if line:match("^Skipped '") then
      skipped = skipped + 1
    end
  end
  if skipped > 0 then
    table.insert(counts, ("%d skipped"):format(skipped))
  end

  local revision = summary.revision and ("r" .. summary.revision) or "the requested revision"

  local message
  if #summary.items == 0 then
    message = ("Nothing to update: at %s"):format(revision)
  else
    message = ("Updated to %s"):format(revision)
  end

  if #counts > 0 then
    message = ("%s (%s)"):format(message, table.concat(counts, ", "))
  end

  if #summary.conflicts == 0 then
    return message, vim.log.levels.INFO
  end

  local lines =
    { message, #summary.conflicts == 1 and "1 conflict:" or ("%d conflicts:"):format(#summary.conflicts) }
  for i, conflict in ipairs(summary.conflicts) do
    if i > 10 then
      table.insert(lines, ("  ... and %d more"):format(#summary.conflicts - 10))
      break
    end

    table.insert(lines, ("  %s (%s)"):format(conflict.path, conflict_kinds(conflict)))
  end

  return table.concat(lines, "\n"), vim.log.levels.WARN
end

---Turns what was typed at the prompt into something `svn update -r` takes.
---@param answer string "42", "r42", "HEAD", "PREV", "{2026-10-01}", ...
---@return string|nil revision nil when it is not a revision
function M.parse_revision(answer)
  local revision = vim.trim(answer)

  if revision:match("^[rR]?%d+$") then
    return (revision:gsub("^[rR]", ""))
  end

  local keyword = revision:upper()
  if keyword == "HEAD" or keyword == "BASE" or keyword == "COMMITTED" or keyword == "PREV" then
    return keyword
  end

  if revision:match("^{.+}$") then
    return revision
  end

  return nil
end

---Runs `svn update` with the arguments of the popup, reports the outcome and fires
---`User SvenUpdateComplete` (data: `{ revision, items, conflicts }`).
---@param popup PopupData
---@param opts { revision: string|number|nil, paths: string[]|nil }
---@return SvenUpdateSummary
local function update(popup, opts)
  -- `--accept` is an argument of its own for the backend, which defaults it to "postpone"
  local args = {}
  local accept
  for _, arg in ipairs(popup:get_arguments()) do
    local value = arg:match("^%-%-accept=(.+)$")
    if value then
      accept = value
    else
      table.insert(args, arg)
    end
  end

  local summary = svn.update.run {
    revision = opts.revision,
    paths = opts.paths,
    accept = accept,
    args = args,
  }

  if summary.ok then
    local message, level = M.describe(summary)
    if level == vim.log.levels.WARN then
      notification.warn(message)
    else
      notification.info(message)
    end

    event.send("UpdateComplete", {
      revision = summary.revision,
      items = summary.items,
      conflicts = summary.conflicts,
    })
  else
    -- svn said why. Whatever it got done before failing is worth showing.
    local status = require("sven.buffers.status").shown()
    if status then
      status:dispatch_refresh(nil, "update_failed")
    end
  end

  return summary
end

---Updates the working copy to HEAD
---@param popup PopupData
function M.head(popup)
  update(popup, {})
end

---Updates the working copy to a revision that is asked for
---@param popup PopupData
function M.revision(popup)
  local suggestion = popup:get_env("revision")
  local answer = input.get_user_input("Update to revision", {
    default = suggestion and tostring(suggestion) or nil,
  })
  if not answer then
    return
  end

  local revision = M.parse_revision(answer)
  if not revision then
    notification.warn(
      ("%q is not a revision. Use a number, HEAD, BASE, COMMITTED, PREV or a date like {2026-10-01}."):format(
        answer
      )
    )
    return
  end

  update(popup, { revision = revision })
end

---Updates only the paths the popup was opened on, to HEAD
---@param popup PopupData
function M.paths(popup)
  local paths = popup:get_env("paths") or {}
  if #paths == 0 then
    notification.info("No file is selected to update")
    return
  end

  update(popup, { paths = paths })
end

return M
