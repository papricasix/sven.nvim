local svn = require("sven.lib.svn")

---`svn update`. Contacts the repository.
---@class SvenUpdate
local M = {}

---@class SvenUpdateItem
---@field path string Path relative to the directory svn ran in (the working copy root)
---@field action string What happened to the item: "A" added, "D" deleted, "U" updated, "C" conflict, "G" merged, "E" existed, "R" replaced, " " nothing
---@field prop_action string What happened to its properties: "U", "C", "G" or " "
---@field lock_broken boolean The lock of the file was broken or stolen
---@field tree_conflict boolean

---@class SvenUpdateConflict
---@field path string
---@field text boolean
---@field prop boolean
---@field tree boolean

---@class SvenUpdateSummary
---@field ok boolean svn exited successfully. Conflicts do not make an update fail
---@field revision number|nil The revision the working copy was updated to
---@field items SvenUpdateItem[] Every item svn touched
---@field counts table<string, number> Number of items per action letter (A, D, U, C, G, E, R). An item counts once: for what happened to its content, else for what happened to its properties, else as a conflict (C) when it is a tree conflict
---@field conflicts SvenUpdateConflict[] Items left in conflict. They show up in `repo.state.conflicts` after the next refresh
---@field result SvenCliResult|nil The raw result of svn

---Parses the output of `svn update`
---@param lines string[]
---@return SvenUpdateSummary
function M.parse(lines)
  local summary = { ---@type SvenUpdateSummary
    ok = true,
    revision = nil,
    items = {},
    counts = {},
    conflicts = {},
  }

  for _, line in ipairs(lines) do
    local action, prop_action, lock, tree, path = line:match("^([ADUCGER ])([UCG ])([B ])([C ]) (.+)$")

    if action and (action .. prop_action .. lock .. tree):match("%S") then
      table.insert(summary.items, {
        path = path,
        action = action,
        prop_action = prop_action,
        lock_broken = lock == "B",
        tree_conflict = tree == "C",
      })

      local counted = action ~= " " and action or prop_action
      if counted == " " and tree == "C" then
        counted = "C"
      end
      if counted ~= " " then
        summary.counts[counted] = (summary.counts[counted] or 0) + 1
      end

      if action == "C" or prop_action == "C" or tree == "C" then
        table.insert(summary.conflicts, {
          path = path,
          text = action == "C",
          prop = prop_action == "C",
          tree = tree == "C",
        })
      end
    else
      local revision = line:match("^Updated to revision (%d+)%.") or line:match("^At revision (%d+)%.")
      if revision then
        summary.revision = tonumber(revision)
      end

      -- With `--accept` svn resolves the conflicts it ran into at the end of the update
      local text_resolved = line:match("^Merge conflicts in '(.+)' marked as resolved%.")
      local prop_resolved = line:match("^Conflict in property '.+' at '(.+)' marked as resolved%.")
      local tree_resolved = line:match("^Tree conflict at '(.+)' marked as resolved%.")
      local all_resolved = line:match("^Resolved conflicted state of '(.+)'")

      for _, conflict in ipairs(summary.conflicts) do
        if conflict.path == text_resolved or conflict.path == all_resolved then
          conflict.text = false
        end
        if conflict.path == prop_resolved or conflict.path == all_resolved then
          conflict.prop = false
        end
        if conflict.path == tree_resolved or conflict.path == all_resolved then
          conflict.tree = false
        end
      end
    end
  end

  summary.conflicts = vim.tbl_filter(function(conflict)
    return conflict.text or conflict.prop or conflict.tree
  end, summary.conflicts)

  return summary
end

---@class SvenUpdateOpts: SvenCliOpts
---@field revision? string|number Update to this revision instead of HEAD (`-r`)
---@field paths? string[] Only update these paths. Defaults to the whole working copy
---@field accept? string How to resolve conflicts. Defaults to "postpone": conflicts are left for the user and end up in `repo.state.conflicts`
---@field args? string[] Additional arguments, e.g. `{ "--ignore-externals" }`

---Updates the working copy.
---
---  local summary = svn.update.run {}
---  if #summary.conflicts > 0 then ... end
---@param opts SvenUpdateOpts|nil
---@return SvenUpdateSummary
function M.run(opts)
  opts = opts or {}

  local args = { "update", "--accept", opts.accept or "postpone" }
  if opts.revision then
    vim.list_extend(args, { "-r", tostring(opts.revision) })
  end
  vim.list_extend(args, opts.args or {})

  local result = svn.cli.run(args, svn.cli.opts(opts, { paths = opts.paths }))

  local summary = M.parse(result.stdout)
  summary.ok = result.code == 0
  summary.result = result

  -- The log moved on, even when the update only got half way
  svn.repo:invalidate_recent()

  return summary
end

return M
