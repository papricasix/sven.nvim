local popup = require("sven.lib.popup")
local actions = require("sven.popups.commit.actions")
local Env = require("sven.popups.diff.env")

local M = {}

---Opens the commit popup.
---@param env table|nil Where the popup is opened from. `paths` (relative to the working copy root) are what the "Commit file" action commits; without any it is the file of the current buffer
---@return PopupData
function M.create(env)
  env = Env.resolve(env)

  local files = actions.files(env)
  local label = #files == 1 and ("Commit %s"):format(vim.fs.basename(files[1]))
    or ("Commit %d files"):format(#files)

  local p = popup
    .builder()
    :name("SvenCommitPopup")
    :switch("u", "no-unlock", "Keep the locks of the committed files")
    :switch("k", "keep-changelists", "Keep the committed files in their changelists")
    :switch("x", "include-externals", "Also commit file and directory externals")
    :group_heading("Create")
    :action("c", "Commit", actions.commit)
    :action("a", "Commit all changes", actions.commit_all)
    :action_if(#files > 0, "f", label, actions.commit_files)
    :env(env)
    :build()

  p:show()

  return p
end

return M
