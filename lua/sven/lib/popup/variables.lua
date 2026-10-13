local state = require("sven.lib.state")

---Backing store for the "Variables" (config) section of popups.
---
---In Neogit this section reads and writes git config. Subversion has nothing comparable that is
---safe to edit from a popup, so the builder API (`PopupBuilder:config`) is kept and the values
---live in sven's own persisted state instead (see `sven.lib.state`). They are plain strings,
---scoped per project when `use_per_project_settings` is enabled.
---@class SvenPopupVariables
local M = {}

local NAMESPACE = "SvenVariables"

---@class ConfigEntry
---@field value string "" when unset
---@field name string
local ConfigEntry = {}
ConfigEntry.__index = ConfigEntry

---@param name string
---@param value string|nil
---@return ConfigEntry
function ConfigEntry.new(name, value)
  return setmetatable({
    name = name,
    value = value or "",
  }, ConfigEntry)
end

---@return string "boolean"|"number"|"string"
function ConfigEntry:type()
  if self.value == "true" or self.value == "false" then
    return "boolean"
  elseif tonumber(self.value) then
    return "number"
  else
    return "string"
  end
end

---@return boolean
function ConfigEntry:is_set()
  return self.value ~= ""
end

---@return boolean
function ConfigEntry:is_unset()
  return not self:is_set()
end

---@return boolean|number|string|nil the value converted to its type, nil when unset
function ConfigEntry:read()
  if self:is_unset() then
    return nil
  end

  if self:type() == "boolean" then
    return self.value == "true"
  elseif self:type() == "number" then
    return tonumber(self.value)
  else
    return self.value
  end
end

---@param value string|nil nil or "" unsets the variable
function ConfigEntry:update(value)
  M.set(self.name, value)
  self.value = value or ""
end

-- Holds the values for the current session when persisting settings is disabled
---@type table<string, string>
local session = {}

---@param name string
---@return ConfigEntry
function M.get(name)
  local value
  if state.enabled() then
    value = state.get({ NAMESPACE, name }, "")
  else
    value = session[name]
  end

  return ConfigEntry.new(name, value ~= nil and tostring(value) or "")
end

---@param name string
---@param value string|nil nil or "" unsets the variable
function M.set(name, value)
  if state.enabled() then
    state.set({ NAMESPACE, name }, value or "")
  else
    session[name] = (value ~= nil and value ~= "") and value or nil
  end
end

---@param name string
function M.unset(name)
  M.set(name, "")
end

return M
