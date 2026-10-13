local actions = require("sven.popups.update.actions")
local svn = require("sven.lib.svn")
local popup = require("sven.lib.popup")

local M = {}

---@param values string[]
---@return PopupConfigOption[]
local function choices(values)
  return vim.tbl_map(function(value)
    return { display = value, value = value }
  end, values)
end

---Opens the update popup, the counterpart of Neogit's pull popup.
---@param env { paths: string[]?, revision: number? }|nil `paths`: what the popup was opened on, offered as "update only this". `revision`: suggested when asking for a revision
---@return PopupData
function M.create(env)
  env = env or {}

  local paths = env.paths or {}
  local only
  if #paths == 1 then
    only = paths[1]
  elseif #paths > 1 then
    only = ("%d selected paths"):format(#paths)
  end

  local info = svn.repo.state.info
  local location = info and info.relative_url or "the working copy"

  local p = popup
    .builder()
    :name("SvenUpdatePopup")
    :switch("e", "ignore-externals", "Ignore externals definitions")
    :switch("f", "force", "Treat unversioned obstructions as changes", { persisted = false })
    -- Neither of these is remembered: a forgotten depth or conflict choice would quietly change
    -- what the next update does.
    :switch(
      "d",
      "",
      "Change the depth of the working copy",
      {
        cli_prefix = "--set-depth=",
        options = choices { "", "exclude", "empty", "files", "immediates", "infinity" },
        persisted = false,
      }
    )
    :switch("a", "postpone", "Resolve conflicts as", {
      cli_prefix = "--accept=",
      options = choices {
        "postpone",
        "working",
        "mine-conflict",
        "theirs-conflict",
        "mine-full",
        "theirs-full",
        "base",
      },
      persisted = false,
    })
    :group_heading("Update " .. location .. " to")
    :action("u", "HEAD", actions.head)
    :action("r", "a revision", actions.revision)
    :new_action_group_if(only ~= nil, "Update only")
    :action_if(only ~= nil, "f", only or "", actions.paths)
    :env({ paths = paths, revision = env.revision })
    :build()

  p:show()

  return p
end

return M
