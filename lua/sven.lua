local M = {}

local did_setup = false

---Setup sven
---@param opts SvenConfig|nil
function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("Sven requires at least NVIM 0.10")
    return
  end

  local config = require("sven.config")
  local signs = require("sven.lib.signs")
  local autocmds = require("sven.autocmds")
  local hl = require("sven.lib.hl")
  local state = require("sven.lib.state")
  local logger = require("sven.logger")

  if did_setup then
    logger.debug("Already did setup!")
    return
  end
  did_setup = true

  M.autocmd_group = vim.api.nvim_create_augroup("Sven", { clear = false })

  M.status = require("sven.buffers.status")

  M.dispatch_reset = function()
    local instance = M.status.instance()
    if instance then
      instance:dispatch_reset()
    end
  end

  M.refresh = function()
    local instance = M.status.instance()
    if instance then
      instance:refresh()
    end
  end

  M.reset = function()
    local instance = M.status.instance()
    if instance then
      instance:reset()
    end
  end

  M.dispatch_refresh = function()
    local instance = M.status.instance()
    if instance then
      instance:dispatch_refresh()
    end
  end

  M.close = function()
    local instance = M.status.instance()
    if instance then
      instance:close()
    end
  end

  M.lib = require("sven.lib")
  M.cli = M.lib.svn.cli
  M.popups = require("sven.popups")
  M.config = config
  M.notification = require("sven.lib.notification")

  config.setup(opts or {})
  hl.setup(config.values)
  signs.setup(config.values)
  state.setup(config.values)
  autocmds.setup()
end

local function construct_opts(opts)
  opts = opts or {}

  if opts.cwd and not opts.no_expand then
    opts.cwd = vim.fn.expand(opts.cwd)
  end

  if not opts.cwd then
    local svn = require("sven.lib.svn")
    opts.cwd = svn.cli.wc_root(".")

    if opts.cwd == "" then
      opts.cwd = vim.uv.cwd()
    end
  end

  return opts
end

local function open_popup(name)
  local popup = require("sven.popups").get(name)
  if popup then
    popup.create {}
  end
end

local function open_status_buffer(opts)
  local status = require("sven.buffers.status")
  local config = require("sven.config")

  -- We need to construct the repo instance manually here since the actual CWD may not be the directory sven is
  -- going to open into. We will use vim.fn.lcd() in the status buffer constructor, so this will eventually be
  -- correct.
  local repo = require("sven.lib.svn.repository").instance(opts.cwd)
  status.new(config.values, repo.root, opts.cwd):open(opts.kind):dispatch_refresh()
end

---@alias Popup
---| "help"
---| "commit"
---| "log"
---| "diff"
---| "update"
---| "resolve"

---@class OpenOpts
---@field cwd string|nil Directory inside the working copy to open. Defaults to the working copy of the current directory
---@field [1] Popup|"blame"|nil Open this popup instead of the status buffer, or blame a file
---@field [2] string|nil For "blame": the file. Defaults to the file of the current buffer
---@field revision string|number|nil For "blame": the revision to show the file in
---@field kind string|nil How to open the status buffer, see `WindowKind`
---@field no_expand boolean|nil Do not expand `cwd`

---Opens the status buffer, or a popup when one is named: `require("sven").open { "commit" }`.
---`require("sven").open { "blame", "src/main.c" }` blames a file instead (the file of the current
---buffer without a path; `revision = 42` for the file as it was in that revision).
---@param opts OpenOpts|nil
function M.open(opts)
  if not did_setup then
    M.setup {}
  end

  -- The file decides which working copy a blame is of, not the current directory
  if opts and opts[1] == "blame" then
    require("sven.buffers.blame_view").open(opts[2], { revision = opts.revision })
    return
  end

  opts = construct_opts(opts)

  local svn = require("sven.lib.svn")
  if not svn.cli.is_inside_working_copy(opts.cwd) then
    M.notification.error(("%s is not inside a Subversion working copy"):format(opts.cwd))
    return
  end

  if opts[1] ~= nil then
    if not M.popups.exists(opts[1]) then
      -- Reports the invalid name
      M.popups.get(opts[1])
      return
    end

    local a = require("sven.lib.async")
    local cb = function()
      open_popup(opts[1])
    end

    local repo = require("sven.lib.svn.repository").instance(opts.cwd)
    a.void(function()
      repo:dispatch_refresh { source = "popup", callback = cb }
    end)()
  else
    open_status_buffer(opts)
  end
end

-- This can be used to create bindable functions for custom keybindings:
--   local sven = require("sven")
--   vim.keymap.set('n', '<leader>sl', sven.action('log', 'log_current', { '--limit=100' }))
--
---@param popup  string Name of popup, as found in `lua/sven/popups/*`
---@param action string Name of action for popup, found in `lua/sven/popups/*/actions.lua`
---@param args   table? CLI arguments to pass to the svn command
---@return function
function M.action(popup, action, args)
  local svn = require("sven.lib.svn")
  local a = require("sven.lib.async")
  local notification = require("sven.lib.notification")

  args = args or {}

  return function()
    a.void(function()
      local ok, actions = pcall(require, "sven.popups." .. popup .. ".actions")
      if ok then
        local fn = actions[action]
        if fn then
          local action = function()
            fn {
              close = function() end,
              state = { env = {} },
              get_arguments = function()
                return args
              end,
              get_internal_arguments = function()
                return {}
              end,
              get_env = function()
                return nil
              end,
            }
          end

          -- Actions are written to run in an async context, as they do when a popup runs them
          svn.repo:dispatch_refresh { source = "action", callback = a.void(action) }
        else
          notification.error(
            string.format(
              "Invalid action %s for %s popup\nValid actions are: %s",
              action,
              popup,
              table.concat(vim.tbl_keys(actions), ", ")
            )
          )
        end
      elseif
        tostring(actions):match("module 'sven%.popups%." .. vim.pesc(popup) .. "%.actions' not found")
      then
        notification.warn(("The %s popup has no actions (yet)"):format(popup))
      else
        notification.error(("Failed to load the actions of popup %q\n%s"):format(popup, actions))
      end
    end)()
  end
end

---Completion for the `:Sven` command
---@param arglead string
---@param cmdline string|nil The command line so far. With it, the subcommands that are not popups are completed as well: `blame` and the file it takes
---@return string[]
function M.complete(arglead, cmdline)
  if cmdline and cmdline:match("Sven!?%s+blame%s") then
    if arglead:find("^revision=") then
      return {}
    end

    return vim.fn.getcompletion(arglead, "file")
  end

  if arglead:find("^kind=") then
    return {
      "kind=replace",
      "kind=tab",
      "kind=split",
      "kind=split_above",
      "kind=split_above_all",
      "kind=split_below",
      "kind=split_below_all",
      "kind=vsplit",
      "kind=floating",
      "kind=auto",
    }
  end

  if arglead:find("^cwd=") then
    return {
      "cwd=" .. vim.uv.cwd(),
    }
  end

  local candidates = { "kind=", "cwd=" }
  vim.list_extend(candidates, require("sven.popups").names)

  -- Only the first argument can be a subcommand
  if cmdline and cmdline:match("Sven!?%s+%S*$") then
    table.insert(candidates, "blame")
  end

  return vim.tbl_filter(function(arg)
    return arg:match("^" .. vim.pesc(arglead))
  end, candidates)
end

function M.get_log_file_path()
  return vim.fn.stdpath("cache") .. "/sven.log"
end

function M.get_config()
  return M.config.values
end

return M
