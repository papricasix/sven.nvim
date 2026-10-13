local popup = require("sven.lib.popup")
local actions = require("sven.popups.log.actions")
local Env = require("sven.popups.diff.env")

local M = {}

---Opens the log popup.
---@param env table|nil Where the popup is opened from. The first of `paths` (relative to the working copy root) is the file the "file" action shows the history of; without any it is the file of the current buffer
---@return PopupData
function M.create(env)
  env = Env.resolve(env)

  local p = popup
    .builder()
    :name("SvenLogPopup")
    :arg_heading("Revision Limiting")
    :option("l", "limit", "256", "Limit number of revisions", { default = "256", key_prefix = "-" })
    :option("s", "search", "", "Search author, date, message and changed paths", { key_prefix = "-" })
    :option("r", "revision", "", "Revision or range (42, 100:50, {2026-01-01}:HEAD)", { key_prefix = "-" })
    :arg_heading("History")
    :switch("c", "stop-on-copy", "Stop at copies: stay on this branch")
    :switch("g", "use-merge-history", "Show the revisions that were merged")
    :arg_heading("Formatting")
    :switch("v", "verbose", "Show changed paths", { enabled = true })
    :group_heading("Log")
    :action("l", "working copy", actions.log_current)
    :action_if(env.file ~= nil, "f", env.file and vim.fs.basename(env.file) or "file", actions.log_file)
    :action("r", "repository", actions.log_repository)
    :action("p", "path or URL", actions.log_other)
    :env(env)
    :build()

  p:show()

  return p
end

return M
