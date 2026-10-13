local svn = require("sven.lib.svn")

---What a popup knows about the place it was opened from.
---
---The status buffer opens popups with an environment: the item, section and revision under the
---cursor and the paths of the selection. Opened with `:Sven log` or from a mapping there is none,
---and "this file" means the file of the current buffer. That has to be found out before the
---popup is shown, because the popup becomes the current buffer.
---
---The commit, log and diff popups pass their environment through `resolve` on creation, and
---their actions read it back with `of`.
local M = {}

---The environment of a popup, completed. What the status buffer passes is the first four fields.
---@class SvenPopupContext
---@field item SvenStatusItem|nil The status item under the cursor
---@field section { name: string }|nil The section under the cursor
---@field revision number|nil The revision under the cursor
---@field paths string[] Paths of the items under the cursor or in the selection, relative to the working copy root
---@field file string|nil The one file "this" refers to: the first path, else the file of the current buffer. Relative to the working copy root
---@field buffer integer|nil The buffer that was current when the popup was created
---@field range { [1]: number, [2]: number }|nil Two revisions of a selection, older first
---@field resolved boolean

---@param buf integer
---@return string|nil relative The file of the buffer, relative to the root of the current working copy
local function buffer_file(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end

  local relative = svn.repo:relpath(name)
  if relative and relative ~= "." then
    return relative
  end
end

---@param revision any
---@return number|nil
local function revision_number(revision)
  if type(revision) == "number" then
    return revision
  elseif type(revision) == "string" then
    return tonumber(revision:match("^[rR]?(%d+)$"))
  end
end

---Completes an environment. Call it while the buffer the popup is opened from is still current.
---@param env table|nil
---@return SvenPopupContext
function M.resolve(env)
  env = env or {}
  if env.resolved then
    return env
  end

  local resolved = vim.tbl_extend("force", {}, env)
  resolved.buffer = vim.api.nvim_get_current_buf()
  resolved.revision = revision_number(env.revision)

  local paths = {}
  for _, path in ipairs(env.paths or {}) do
    if type(path) == "string" and path ~= "" then
      table.insert(paths, path)
    end
  end

  if #paths == 0 and env.item and type(env.item.name) == "string" and not env.revision then
    table.insert(paths, env.item.name)
  end

  resolved.paths = svn.cli.relative_paths(paths)
  resolved.file = resolved.paths[1] or buffer_file(resolved.buffer)
  resolved.resolved = true

  return resolved
end

---The environment of a popup, for its actions. Works for the stand-in that
---`require("sven").action()` passes instead of a popup as well.
---@param popup PopupData
---@return SvenPopupContext
function M.of(popup)
  local env = popup.state and popup.state.env or {}
  if not env.resolved then
    env = M.resolve(env)
    if popup.state then
      popup.state.env = env
    end
  end

  return env
end

return M
