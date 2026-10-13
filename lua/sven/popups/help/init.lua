local popup = require("sven.lib.popup")
local actions = require("sven.popups.help.actions")

local M = {}

---Opens the help popup: the keys of the status buffer, generated from the configured mappings.
---@param env SvenPopupEnv|nil What the cursor was on. Handed to the popup that is opened from here
---@return PopupData
function M.create(env)
  env = env or {}

  local p = popup.builder():name("SvenHelpPopup"):group_heading("Commands")

  local popups = actions.popups(env)
  for i, cmd in ipairs(popups) do
    p = p:action(cmd.keys, cmd.name, cmd.fn)

    if i == math.floor(#popups / 2) then
      p = p:new_action_group()
    end
  end

  p = p:new_action_group():new_action_group("Applying changes")
  for _, cmd in ipairs(actions.actions()) do
    p = p:action(cmd.keys, cmd.name, cmd.fn)
  end

  p = p:new_action_group():new_action_group("Essential commands")
  for _, cmd in ipairs(actions.essential()) do
    p = p:action(cmd.keys, cmd.name, cmd.fn)
  end

  p = p:build()
  p:show()

  return p
end

return M
