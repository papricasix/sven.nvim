local svn = require("sven.lib.svn")
local notification = require("sven.lib.notification")

---`svn resolve`. Needs no network access.
---@class SvenResolve
local M = {}

---The ways a conflict can be resolved without a prompt.
---
---  working          what is in the working file now (after editing out the conflict markers)
---  mine-full        the local version of the whole file
---  theirs-full      the incoming version of the whole file
---  base             the common ancestor
---  mine-conflict    the local version for conflicting hunks, merged otherwise
---  theirs-conflict  the incoming version for conflicting hunks, merged otherwise
---
---Tree conflicts only accept "working".
---@type string[]
M.choices = { "working", "mine-full", "theirs-full", "base", "mine-conflict", "theirs-conflict" }

---@class SvenResolveOpts: SvenCliOpts
---@field depth? string Resolve below directories as well: "infinity". Defaults to the paths themselves

---Resolves the conflicts of paths.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param choice string One of `M.choices`
---@param opts SvenResolveOpts|nil
---@return boolean ok
---@return SvenCliResult|nil result
function M.accept(paths, choice, opts)
  opts = opts or {}

  if not vim.tbl_contains(M.choices, choice) then
    notification.error(
      ("Invalid way to resolve a conflict: %q\nValid ones are: %s"):format(
        tostring(choice),
        table.concat(M.choices, ", ")
      )
    )
    return false, nil
  end

  if not paths or #paths == 0 then
    return true, nil
  end

  local args = { "resolve", "--accept", choice }
  if opts.depth then
    vim.list_extend(args, { "--depth", opts.depth })
  end

  -- Not forced to block: svn resolve waits for the clock after writing working files, for up to
  -- a second, which would freeze the editor.
  local result = svn.cli.run(args, svn.cli.opts(opts, { paths = paths }))

  return result.code == 0, result
end

---Resolves every conflict in the working copy the same way.
---@param choice string One of `M.choices`
---@param opts SvenResolveOpts|nil
---@return boolean ok
---@return SvenCliResult|nil result
function M.all(choice, opts)
  return M.accept({ "." }, choice, vim.tbl_extend("force", opts or {}, { depth = "infinity" }))
end

return M
