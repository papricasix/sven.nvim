local popup = require("sven.lib.popup")
local actions = require("sven.popups.resolve.actions")
local notification = require("sven.lib.notification")
local util = require("sven.lib.util")

local M = {}

---@param choice SvenResolveChoice
---@param describe boolean
---@return string
local function label(choice, describe)
  if describe then
    return ("%s  %s"):format(util.pad_right(choice.name, 15), choice.description)
  end

  return choice.name
end

---Opens the resolve popup.
---
---The lower case keys resolve the conflicted paths of `env.paths` (the file or selection the
---popup was opened on), the upper case keys every conflict of the working copy.
---@param env { paths: string[]? }|nil
---@return PopupData|nil popup nil when there is nothing to resolve
function M.create(env)
  env = env or {}

  local all = actions.conflicts()
  if #all == 0 then
    notification.info("There are no conflicts in this working copy")
    return nil
  end

  local selected = actions.conflicts(env.paths or {})

  local p = popup.builder():name("SvenResolvePopup")

  if #selected > 0 then
    local target = #selected == 1 and selected[1].name or ("%d selected conflicts"):format(#selected)

    p = p:group_heading("Resolve " .. target .. " as")
    for _, choice in ipairs(actions.choices) do
      p = p:action(choice.key, label(choice, true), actions[choice.action])
    end

    p = p:new_action_group(("Resolve all conflicts (%d) as"):format(#all))
  else
    p = p:group_heading(("Resolve all conflicts (%d) as"):format(#all))
  end

  for _, choice in ipairs(actions.choices) do
    -- The descriptions are shown once
    p = p:action(choice.key:upper(), label(choice, #selected == 0), actions["all_" .. choice.action])
  end

  p = p:env(env):build()
  p:show()

  return p
end

return M
