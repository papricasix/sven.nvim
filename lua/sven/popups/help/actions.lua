local M = {}

local util = require("sven.lib.util")
local config = require("sven.config")
local NONE = function() end

---Turns commands into the entries of the help popup: their name, the keys they are mapped to,
---and what to run when one of those keys is pressed in the popup.
---@param commands table[] `{ command, name, fn }`: a command of `config.mappings.status` or `config.mappings.popup`
---@return { name: string, keys: string[], cmp: string, fn: function }[] Sorted by key
local function present(commands)
  -- Looked up on every call: the mappings may have been configured after this module was loaded
  local status_mappings = config.get_reversed_status_maps()
  local popup_mappings = config.get_reversed_popup_maps()

  local presenter = util.map(commands, function(command)
    local cmd, name, fn = unpack(command)

    --- Handle the longer table mapping form (mode, func, esc)
    if type(fn) == "table" then
      fn = fn[2]
    end

    local keymap = status_mappings[cmd]
    if not keymap or keymap == "<nop>" then
      keymap = popup_mappings[cmd]
    end

    if type(keymap) == "table" and next(keymap) then
      -- The popup must not change what the mappings look up
      keymap = vim.list_slice(keymap)

      -- HACK: Remove "za" as listed keymap for toggle action.
      table.sort(keymap)
      if name == "Toggle" and keymap[2] == "za" then
        table.remove(keymap, 2)
      end

      return { { name = name, keys = keymap, cmp = table.concat(keymap):lower(), fn = fn } }
    else
      return { { name = name, keys = {}, cmp = "", fn = fn } }
    end
  end)

  presenter = util.flatten(presenter)

  table.sort(presenter, function(a, b)
    return a.cmp < b.cmp
  end)

  return presenter
end

---The popups of sven and the commands that open something, each run with the context the help
---popup was opened in.
---@param env SvenPopupEnv|nil
M.popups = function(env)
  local popups = require("sven.popups")

  local function open(name)
    return popups.open(name, function(p)
      p(env)
    end)
  end

  local items = {
    {
      "CommandHistory",
      "History",
      function()
        require("sven.buffers.command_history"):new():show()
      end,
    },
    { "DiffPopup", "Diff", open("diff") },
    { "UpdatePopup", "Update", open("update") },
    { "CommitPopup", "Commit", open("commit") },
    { "LogPopup", "Log", open("log") },
    { "ResolvePopup", "Resolve", open("resolve") },
    { "Command", "Command", require("sven.buffers.status.actions").n_command(nil) },
  }

  return present(items)
end

M.actions = function()
  return present {
    { "Stage", "Stage", NONE },
    { "StageUnstaged", "Stage changes", NONE },
    { "StageAll", "Stage all", NONE },
    { "Unstage", "Unstage", NONE },
    { "UnstageStaged", "Unstage all", NONE },
    { "Discard", "Discard", NONE },
  }
end

M.essential = function()
  return present {
    {
      "RefreshBuffer",
      "Refresh",
      function()
        local status = require("sven.buffers.status").shown()
        if status then
          require("sven.lib.svn").repo:invalidate_recent()
          status:dispatch_refresh(nil, "user_refresh")
        end
      end,
    },
    { "GoToFile", "Go to file", NONE },
    { "Toggle", "Toggle", NONE },
    { "Blame", "Blame", NONE },
  }
end

return M
