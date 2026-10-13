---Registry and dispatcher for popups.
---
---A popup lives in `lua/sven/popups/<name>/init.lua` and exposes `create(env?)`, which builds
---it with `require("sven.lib.popup").builder()` and shows it. Popups are required lazily, so a
---popup that has not been written yet results in a notification instead of an error.
---@class Popups
---@field names string[] Every popup name, in the order they are offered for completion
local M = {}

---Popups of sven. Each has a mapping named `<Name>Popup` in `config.mappings.popup`.
M.names = {
  "help",
  "commit",
  "log",
  "diff",
  "update",
  "resolve",
}

---@param name string
---@return boolean
function M.exists(name)
  return vim.tbl_contains(M.names, name)
end

---@param name string
---@return string The name of the mapping that opens the popup: "commit" -> "CommitPopup"
function M.mapping_name(name)
  return name:sub(1, 1):upper() .. name:sub(2) .. "Popup"
end

---Loads a popup module.
---@param name string
---@return table|nil popup The module, nil if it could not be loaded
---@return string|nil reason "invalid" (no such popup), "missing" (not implemented yet) or "error" (failed to load)
---@return string|nil message Error message when loading failed
function M.load(name)
  if not M.exists(name) then
    return nil, "invalid", nil
  end

  local module = "sven.popups." .. name
  local ok, value = pcall(require, module)
  if ok then
    if type(value) == "table" and type(value.create) == "function" then
      return value, nil, nil
    end

    return nil, "error", ("%s does not provide a create() function"):format(module)
  end

  if tostring(value):match("module '" .. vim.pesc(module) .. "' not found") then
    return nil, "missing", nil
  end

  return nil, "error", tostring(value)
end

---Loads a popup module, telling the user when that is not possible.
---@param name string
---@return table|nil popup
function M.get(name)
  local notification = require("sven.lib.notification")

  local popup, reason, message = M.load(name)
  if popup then
    return popup
  end

  if reason == "invalid" then
    notification.error(("Invalid popup %q\nValid popups are: %s"):format(name, table.concat(M.names, ", ")))
  elseif reason == "missing" then
    notification.warn(("The %s popup is not implemented yet"):format(name))
  else
    notification.error(string.format("Failed to load popup: %q\n%s", name, message))
  end

  return nil
end

---Creates a curried function which will open the popup with the given name when called
---@param name string
---@param f nil|fun(create: fun(...)): any Receives the popup's `create`, to call it with an environment
---@return fun(): any
function M.open(name, f)
  f = f or function(c)
    c()
  end

  return function()
    local popup = M.get(name)
    if popup then
      f(popup.create)
    end
  end
end

---Returns the keymapping for a popup
---@param name string Name of the mapping, e.g. "CommitPopup"
---@return string|string[]
function M.mapping_for(name)
  local mappings = require("sven.config").get_reversed_popup_maps()

  if mappings[name] then
    return mappings[name]
  else
    return {}
  end
end

return M
