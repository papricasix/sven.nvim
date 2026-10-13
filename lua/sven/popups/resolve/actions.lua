local svn = require("sven.lib.svn")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local event = require("sven.lib.event")
local util = require("sven.lib.util")

---Resolving conflicts. Used by the resolve popup, and by the status buffer when a conflicted
---file is staged.
local M = {}

---@class SvenResolveChoice
---@field name string What `svn resolve --accept` takes
---@field key string Key in the popup. The upper case key does the same for every conflict
---@field action string Name of the function of this module that resolves the selected paths. `all_<action>` resolves every conflict
---@field description string One line about what is left in the working file
---@field destructive boolean Local changes get lost

---The ways to resolve a conflict, in the order the popup offers them
---@type SvenResolveChoice[]
M.choices = {
  {
    name = "working",
    key = "w",
    action = "working",
    description = "the file as it is now, edited by hand",
    destructive = false,
  },
  {
    name = "mine-full",
    key = "m",
    action = "mine_full",
    description = "my file as a whole, without any incoming change",
    destructive = false,
  },
  {
    name = "theirs-full",
    key = "t",
    action = "theirs_full",
    description = "their file as a whole, dropping all my changes",
    destructive = true,
  },
  {
    name = "base",
    key = "b",
    action = "base",
    description = "the file before either side changed it",
    destructive = true,
  },
  {
    name = "mine-conflict",
    key = "c",
    action = "mine_conflict",
    description = "both merged, my side where they conflict",
    destructive = false,
  },
  {
    name = "theirs-conflict",
    key = "o",
    action = "theirs_conflict",
    description = "both merged, their side where they conflict",
    destructive = true,
  },
}

---@param name string
---@return SvenResolveChoice|nil
local function find_choice(name)
  for _, choice in ipairs(M.choices) do
    if choice.name == name then
      return choice
    end
  end
end

-- Larger files are not searched for conflict markers
local MAX_SCANNED_BYTES = 8 * 1024 * 1024

---Whether a text-conflicted file still contains the markers svn put into it
---(`<<<<<<< .mine` ... `>>>>>>> .r5`).
---@param item SvenStatusItem
---@return boolean
function M.has_conflict_markers(item)
  if not item.text_conflicted or item.kind == "dir" then
    return false
  end

  local stat = vim.uv.fs_stat(item.absolute_path)
  if not stat or stat.type ~= "file" or stat.size > MAX_SCANNED_BYTES then
    return false
  end

  local fd = io.open(item.absolute_path, "rb")
  if not fd then
    return false
  end

  local content = "\n" .. (fd:read("*a") or "")
  fd:close()

  return content:find("\n<<<<<<< ", 1, true) ~= nil and content:find("\n>>>>>>> ", 1, true) ~= nil
end

---The conflicted items of the current working copy.
---@param paths string[]|nil Only these paths (relative to the working copy root). nil for every conflict
---@return SvenStatusItem[]
function M.conflicts(paths)
  local items = svn.repo.state.conflicts.items
  if not paths then
    return vim.list_slice(items)
  end

  local wanted = util.build_reverse_lookup(paths)
  return vim.tbl_filter(function(item)
    return wanted[item.name] ~= nil
  end, items)
end

---@param items SvenStatusItem[]
---@return string One indented line per item
local function list(items)
  local lines = {}
  for i, item in ipairs(items) do
    if i > 10 then
      table.insert(lines, ("  ... and %d more"):format(#items - 10))
      break
    end

    table.insert(lines, "  " .. item.name)
  end

  return table.concat(lines, "\n")
end

---@param items SvenStatusItem[]
---@return string
local function subject(items)
  if #items == 1 then
    return ("%q"):format(items[1].name)
  end

  return ("these %d conflicts"):format(#items)
end

---Asks before something is lost.
---@param items SvenStatusItem[]
---@param choice SvenResolveChoice
---@return boolean go_ahead
local function confirm(items, choice)
  local details = #items > 1 and ("\n" .. list(items)) or ""

  if choice.name == "working" then
    local unedited = vim.tbl_filter(M.has_conflict_markers, items)
    if #unedited == 0 then
      return true
    end

    if #items == 1 then
      return input.get_permission(
        ("%q still contains conflict markers. Mark it as resolved anyway?"):format(items[1].name)
      )
    end

    return input.get_permission(
      ("%d of %d files still contain conflict markers:\n%s\nMark all %d as resolved anyway?"):format(
        #unedited,
        #items,
        list(unedited),
        #items
      )
    )
  end

  if choice.destructive then
    return input.get_permission(
      ("Resolve %s with %s (%s)? Local changes are lost.%s"):format(
        subject(items),
        choice.name,
        choice.description,
        details
      )
    )
  end

  return true
end

---Resolves conflicts, after asking when that loses something.
---
---Must be called inside an async context (a popup action, `a.void`): svn runs in the background.
---Fires `User SvenResolveComplete` with `data = { paths, choice }` when svn is done.
---@param items SvenStatusItem[] Conflicted items
---@param choice_name string One of `sven.lib.svn.resolve.choices`
---@param opts { stage: boolean? }|nil `stage` puts the resolved files into the staging changelist
---@return boolean ok Whether the conflicts were resolved
---@return string[] paths The paths that were resolved
function M.resolve(items, choice_name, opts)
  opts = opts or {}

  local choice = find_choice(choice_name)
  if not choice then
    notification.error(("Invalid way to resolve a conflict: %q"):format(tostring(choice_name)))
    return false, {}
  end

  if #items == 0 then
    notification.info("There is no conflict to resolve here")
    return false, {}
  end

  -- svn refuses anything but "working" for tree conflicts
  local accepted = {}
  local refused = {}
  for _, item in ipairs(items) do
    if item.tree_conflicted and choice.name ~= "working" then
      table.insert(refused, item)
    else
      table.insert(accepted, item)
    end
  end

  if #refused > 0 then
    notification.warn(
      ("Tree conflicts cannot be resolved with %s: sort out the tree by hand, then resolve as working.\n%s"):format(
        choice.name,
        list(refused)
      )
    )
  end

  if #accepted == 0 or not confirm(accepted, choice) then
    return false, {}
  end

  local paths = util.map(accepted, function(item)
    return item.name
  end)

  local ok = svn.resolve.accept(paths, choice.name)
  if not ok then
    return false, {}
  end

  local message = ("Resolved %s as %s"):format(
    #paths == 1 and paths[1] or ("%d conflicts"):format(#paths),
    choice.name
  )
  if opts.stage and svn.changelist.stage(paths) then
    message = ("%s and staged %s"):format(message, #paths == 1 and "it" or "them")
  end

  notification.info(message)
  event.send("ResolveComplete", { paths = paths, choice = choice.name })

  return true, paths
end

-- One action per choice for the paths the popup was opened on, one for every conflict:
-- `M.theirs_full(popup)` and `M.all_theirs_full(popup)`.
for _, choice in ipairs(M.choices) do
  ---@param popup PopupData
  M[choice.action] = function(popup)
    M.resolve(M.conflicts(popup:get_env("paths") or {}), choice.name)
  end

  M["all_" .. choice.action] = function()
    M.resolve(M.conflicts(), choice.name)
  end
end

return M
