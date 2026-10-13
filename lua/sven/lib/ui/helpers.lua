local M = {}

---Modules that failed to load, so that a missing view is only looked up once.
---@type table<string, boolean>
local missing = {}

---Requires a module that may not exist (yet), returning nil instead of raising.
---Used for views that are provided by other parts of the plugin and referenced from the UI core.
---@param name string
---@return table|nil
function M.optional_require(name)
  if package.loaded[name] then
    return package.loaded[name]
  end

  if missing[name] then
    return nil
  end

  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then
    return mod
  end

  missing[name] = true
  if not ok and not tostring(mod):match("module '" .. vim.pesc(name) .. "' not found") then
    require("sven.logger").error(("[UI] Failed to load %q: %s"):format(name, mod))
  end

  return nil
end

---The revision view: the svn counterpart of Neogit's commit view.
---
---It is looked up as `sven.buffers.revision_view`, falling back to `sven.buffers.commit_view`.
---The UI core uses, when present: `is_open(): boolean`, `instance` (with `:close()`), and
---`current_oid(): string|nil` (the id of the shown revision, matched against the `oid` option of
---components to draw the "active item" highlight in list buffers).
---@return table|nil
function M.revision_view()
  return M.optional_require("sven.buffers.revision_view") or M.optional_require("sven.buffers.commit_view")
end

---Closable must implement self:close() method
---@return function
function M.close_topmost(closable)
  return function()
    local revision_view = M.revision_view()
    local popup = require("sven.lib.popup")
    local history = require("sven.buffers.command_history")

    if popup.is_open() then
      popup.instance:close()
    elseif revision_view and revision_view.is_open and revision_view.is_open() then
      revision_view.instance:close()
    elseif history.is_open() then
      history.instance:close()
    else
      closable:close()
    end
  end
end

return M
