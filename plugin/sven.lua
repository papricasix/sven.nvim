local api = vim.api

-- :Sven                 open the status buffer for the working copy of the current directory
-- :Sven kind=split      ... in a split (see `WindowKind` for all kinds)
-- :Sven cwd=~/src/wc    ... for another working copy
-- :Sven commit          open a popup: help, commit, log, diff, update, resolve
-- :Sven blame [file]    blame a file (the current one by default); again to close the blame
-- :Sven blame [file] revision=42   ... as it was in that revision
api.nvim_create_user_command("Sven", function(o)
  local sven = require("sven")
  sven.open(require("sven.lib.util").parse_command_args(o.fargs))
end, {
  nargs = "*",
  desc = "Open Sven",
  complete = function(arglead, cmdline)
    local sven = require("sven")
    return sven.complete(arglead, cmdline)
  end,
})

api.nvim_create_user_command("SvenResetState", function()
  local state = require("sven.lib.state")
  if not state.loaded then
    state.setup(require("sven.config").values)
  end

  state._reset()
end, { nargs = "*", desc = "Reset any saved flags" })
