local config = require("sven.config")
local Buffer = require("sven.lib.buffer")
local ui = require("sven.buffers.status.ui")
local popups = require("sven.popups")
local svn = require("sven.lib.svn")
local Watcher = require("sven.watcher")
local a = require("sven.lib.async")
local logger = require("sven.logger")
local event = require("sven.lib.event")

---The status buffer: a port of Neogit's `buffers/status` onto a Subversion working copy.
---
---One instance per directory it was opened for. What it shows is `svn.repo.state`, the state of
---the current repository, which the instance makes its own working copy whenever it is entered.
---@class StatusBuffer
---@field buffer Buffer|nil The buffer, while it is open
---@field config SvenConfig
---@field root string Working copy root
---@field cwd string Directory the buffer was opened for
---@field fold_state table|nil Folds to restore when the buffer is opened again
---@field cursor_state number|nil Cursor line to restore when the buffer is opened again
---@field view_state table|nil View to restore when the buffer is opened again
---@field cursor_placed boolean|nil The cursor has been put on the first section since the buffer was opened
---@field announcing boolean|nil An event of its own is being fired, see `announce`
---@field prev_autochdir boolean|nil The value of 'autochdir' to put back when the buffer goes away
local M = {}
M.__index = M

local instances = {}

---@param instance StatusBuffer
---@param dir string
function M.register(instance, dir)
  local dir = vim.fs.normalize(dir)
  logger.debug("[STATUS] Registering instance for: " .. dir)

  instances[dir] = instance
end

---@param dir? string Defaults to the current working directory
---@return StatusBuffer|nil
function M.instance(dir)
  local dir = dir or vim.uv.cwd()
  assert(dir, "cannot locate a status buffer with no cwd")

  return instances[vim.fs.normalize(dir)]
end

---@param config SvenConfig
---@param root string Working copy root
---@param cwd string Directory to open the buffer for
---@return StatusBuffer
function M.new(config, root, cwd)
  local existing = M.instance(cwd)
  if existing then
    logger.debug("Found instance for cwd " .. cwd)
    return existing
  end

  local instance = {
    config = config,
    root = root,
    cwd = vim.fs.normalize(cwd),
    buffer = nil,
    fold_state = nil,
    cursor_state = nil,
    view_state = nil,
  }

  setmetatable(instance, M)
  M.register(instance, cwd)

  return instance
end

---@return boolean Whether the status buffer of the current working directory is visible
function M.is_open()
  local instance = M.instance()
  return (instance and instance.buffer and instance.buffer:is_visible()) == true
end

---The status buffer of the current repository, when it is shown in a window of any tab page.
---
---Unlike `instance()` this does not depend on the working directory of whoever asks, which is
---what something that happens elsewhere needs: a file being written in another window or tab.
---@return StatusBuffer|nil
function M.shown()
  local root = svn.repo.root
  if root == "" then
    return nil
  end

  for _, instance in pairs(instances) do
    local buffer = instance.buffer
    if instance.root == root and buffer and buffer:is_valid() and #vim.fn.win_findbuf(buffer.handle) > 0 then
      return instance
    end
  end

  return nil
end

---@param name string Name of a function of `sven.buffers.status.actions`
---@return fun()
function M:_action(name)
  local action = require("sven.buffers.status.actions")[name]
  assert(action, ("Status Buffer action %q is undefined"):format(name))

  return action(self)
end

---@param kind WindowKind|nil
---@return StatusBuffer
function M:open(kind)
  if self.buffer and self.buffer:is_visible() then
    logger.debug("[STATUS] An Instance is already open - focusing it")
    self.buffer:focus()
    return self
  end

  local mappings = config.get_reversed_status_maps()

  self.buffer = Buffer.create {
    name = "SvenStatus",
    filetype = "SvenStatus",
    cwd = self.cwd,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    kind = kind or config.values.kind or "tab",
    disable_line_numbers = config.values.disable_line_numbers,
    disable_relative_line_numbers = config.values.disable_relative_line_numbers,
    foldmarkers = not config.values.disable_signs,
    active_item_highlight = true,
    on_detach = function()
      Watcher.instance(self.root):unregister(self)

      if self.prev_autochdir then
        vim.o.autochdir = self.prev_autochdir
      end
    end,
    --stylua: ignore start
    mappings = {
      v = {
        [mappings["Discard"]]                  = self:_action("v_discard"),
        [mappings["Stage"]]                    = self:_action("v_stage"),
        [mappings["Unstage"]]                  = self:_action("v_unstage"),
        [mappings["YankSelected"]]             = self:_action("v_yank_selected"),
        [popups.mapping_for("HelpPopup")]      = self:_action("v_help_popup"),
        [popups.mapping_for("CommitPopup")]    = self:_action("v_commit_popup"),
        [popups.mapping_for("LogPopup")]       = self:_action("v_log_popup"),
        [popups.mapping_for("DiffPopup")]      = self:_action("v_diff_popup"),
        [popups.mapping_for("UpdatePopup")]    = self:_action("v_update_popup"),
        [popups.mapping_for("ResolvePopup")]   = self:_action("v_resolve_popup"),
      },
      n = {
        [mappings["Command"]]                  = self:_action("n_command"),
        [mappings["OpenTree"]]                 = self:_action("n_open_tree"),
        [mappings["MoveDown"]]                 = self:_action("n_down"),
        [mappings["MoveUp"]]                   = self:_action("n_up"),
        [mappings["Toggle"]]                   = self:_action("n_toggle"),
        [mappings["OpenFold"]]                 = self:_action("n_open_fold"),
        [mappings["CloseFold"]]                = self:_action("n_close_fold"),
        [mappings["Close"]]                    = self:_action("n_close"),
        [mappings["OpenOrScrollDown"]]         = self:_action("n_open_or_scroll_down"),
        [mappings["OpenOrScrollUp"]]           = self:_action("n_open_or_scroll_up"),
        [mappings["PeekDown"]]                 = self:_action("n_peek_down"),
        [mappings["PeekUp"]]                   = self:_action("n_peek_up"),
        [mappings["RefreshBuffer"]]            = self:_action("n_refresh_buffer"),
        [mappings["Depth1"]]                   = self:_action("n_depth1"),
        [mappings["Depth2"]]                   = self:_action("n_depth2"),
        [mappings["Depth3"]]                   = self:_action("n_depth3"),
        [mappings["Depth4"]]                   = self:_action("n_depth4"),
        [mappings["CommandHistory"]]           = self:_action("n_command_history"),
        [mappings["YankSelected"]]             = self:_action("n_yank_selected"),
        [mappings["Discard"]]                  = self:_action("n_discard"),
        [mappings["GoToNextHunkHeader"]]       = self:_action("n_go_to_next_hunk_header"),
        [mappings["GoToPreviousHunkHeader"]]   = self:_action("n_go_to_previous_hunk_header"),
        [mappings["Stage"]]                    = self:_action("n_stage"),
        [mappings["StageAll"]]                 = self:_action("n_stage_all"),
        [mappings["StageUnstaged"]]            = self:_action("n_stage_unstaged"),
        [mappings["Unstage"]]                  = self:_action("n_unstage"),
        [mappings["UnstageStaged"]]            = self:_action("n_unstage_staged"),
        [mappings["Blame"]]                    = self:_action("n_blame"),
        [mappings["GoToFile"]]                 = self:_action("n_goto_file"),
        [mappings["PeekFile"]]                 = self:_action("n_peek_file"),
        [mappings["TabOpen"]]                  = self:_action("n_tab_open"),
        [mappings["SplitOpen"]]                = self:_action("n_split_open"),
        [mappings["VSplitOpen"]]               = self:_action("n_vertical_split_open"),
        [mappings["NextSection"]]              = self:_action("n_next_section"),
        [mappings["PreviousSection"]]          = self:_action("n_prev_section"),
        [popups.mapping_for("HelpPopup")]      = self:_action("n_help_popup"),
        [popups.mapping_for("CommitPopup")]    = self:_action("n_commit_popup"),
        [popups.mapping_for("LogPopup")]       = self:_action("n_log_popup"),
        [popups.mapping_for("DiffPopup")]      = self:_action("n_diff_popup"),
        [popups.mapping_for("UpdatePopup")]    = self:_action("n_update_popup"),
        [popups.mapping_for("ResolvePopup")]   = self:_action("n_resolve_popup"),
        ["V"]                                  = function()
          vim.cmd("norm! V")
        end,
      },
    },
    --stylua: ignore end
    user_mappings = config.get_user_mappings("status"),
    initialize = function()
      self.prev_autochdir = vim.o.autochdir
      vim.o.autochdir = false
    end,
    render = function()
      return ui.Status(svn.repo.state, self.config)
    end,
    ---@param buffer Buffer
    ---@param _win any
    after = function(buffer, _win)
      Watcher.instance(self.root):register(self)

      -- Nothing may be known about the working copy yet. `redraw` puts the cursor on the first
      -- section once there is one.
      local first = buffer.ui:first_section().first
      buffer:move_cursor(first)
      self.cursor_placed = first ~= nil
    end,
    user_autocmds = {
      -- The recent log entries arrive after the refresh that asked for them
      ["SvenRecentLoaded"] = function()
        self:redraw()
      end,
      -- Fired by whoever changed the working copy: the commit, update and resolve popups, and
      -- the views that revert
      ["SvenCommitComplete"] = self:deferred_refresh("commit", 0),
      ["SvenUpdateComplete"] = self:deferred_refresh("update", 0),
      ["SvenResolveComplete"] = self:deferred_refresh("resolve", 0),
      ["SvenRevertComplete"] = self:deferred_refresh("revert", 0),
    },
    autocmds = {
      ["FocusGained"] = self:deferred_refresh("focused", 10),
      -- One repository is current at a time: the one of the status buffer that was entered last
      ["BufEnter"] = function()
        require("sven.lib.svn.repository").instance(self.cwd)
      end,
    },
  }

  return self
end

function M:close()
  if self.buffer then
    -- The buffer may have been wiped out behind our back, e.g. by `:bwipeout`
    if self.buffer:is_valid() then
      self.fold_state = self.buffer.ui:get_fold_state()

      -- Cursor and view are those of the current window
      if self.buffer:is_focused() then
        self.cursor_state = self.buffer:cursor_line()
        self.view_state = self.buffer:save_view()
      end
    end

    logger.debug("[STATUS] Closing Buffer")
    self.buffer:close()
    self.buffer = nil
  end
end

function M:focus()
  if self.buffer then
    logger.debug("[STATUS] Focusing Buffer")
    self.buffer:focus()
  end
end

---Where the cursor is, in terms of what is shown (section, file, hunk), and the view.
---
---Taken from the window of the buffer, which need not be the current one: a refresh can be
---caused elsewhere, by a file that is written in another window.
---@return CursorLocation|nil cursor nil when the buffer is not shown
---@return table|nil view
function M:position()
  local cursor, view

  if self.buffer and self.buffer:is_valid() then
    self.buffer:win_call(function()
      if self.buffer:is_focused() then
        cursor = self.buffer.ui:get_cursor_location()
        view = self.buffer:save_view()
      end
    end)
  end

  return cursor, view
end

---Refreshes the state of the working copy, then redraws.
---@param partial table|nil See `SvenRefreshOpts.partial`: `{ update_diffs = { "*:path" } }` keeps every other cached diff
---@param reason string|nil For the log
function M:refresh(partial, reason)
  logger.debug("[STATUS] Beginning refresh from " .. (reason or "UNKNOWN"))

  -- Needs to be captured _before_ refresh because the diffs are needed, but will be changed by refreshing.
  local cursor, view = self:position()

  svn.repo:dispatch_refresh {
    source = "status",
    partial = partial,
    callback = function()
      self:redraw(cursor, view)
      event.send("StatusRefreshed")
      logger.info("[STATUS] Refresh complete")
    end,
  }
end

---Renders the state of the working copy as it is known, without asking svn.
---@param cursor CursorLocation? Where the cursor was before the state changed. Defaults to where it is now
---@param view table?
function M:redraw(cursor, view)
  if not self.buffer or not self.buffer:is_valid() then
    logger.debug("[STATUS] Buffer no longer exists - bail")
    return
  end

  -- Whoever redraws without having asked for the refresh (the watcher, the arrival of the log
  -- entries) has not noted where the cursor was. What is shown still is the previous state.
  if not cursor then
    cursor, view = self:position()
  end

  logger.debug("[STATUS] Rendering UI")
  self.buffer.ui:render(unpack(ui.Status(svn.repo.state, self.config)))

  if self.fold_state and self.buffer then
    logger.debug("[STATUS] Restoring fold state")
    self.buffer.ui:set_fold_state(self.fold_state)
    self.fold_state = nil
  end

  if self.cursor_state and self.view_state and self.buffer then
    logger.debug("[STATUS] Restoring cursor and view state")
    self.buffer:restore_view(self.view_state, self.cursor_state)
    self.view_state = nil
    self.cursor_state = nil
    self.cursor_placed = true
  elseif not self.cursor_placed and self.buffer then
    local first = self.buffer.ui:first_section().first
    if first then
      self.buffer:win_call(function()
        pcall(vim.api.nvim_win_set_cursor, 0, { first, 0 })
      end)
      self.cursor_placed = true
    end
  elseif cursor and view and self.buffer then
    -- Above the sections there is nothing to follow: the cursor stays on its line
    local line = cursor.section and self.buffer.ui:resolve_cursor_location(cursor) or nil
    self.buffer:restore_view(view, line)
  end
end

---Fires a `User` event (`Sven<name>`) for other views, without refreshing because of it: the
---caller refreshes this buffer itself, and knows which diffs are stale.
---@param name string Event name without the `Sven` prefix, e.g. "RevertComplete"
---@param data table|nil
function M:announce(name, data)
  self.announcing = true
  local ok, err = pcall(event.send, name, data)
  self.announcing = false

  if not ok then
    logger.error(("[STATUS] A handler of Sven%s failed: %s"):format(name, err))
  end
end

local refresh_scheduled = false

M.dispatch_refresh = a.void(function(self, partial, reason)
  if refresh_scheduled then
    return
  end

  refresh_scheduled = true

  vim.schedule(function()
    refresh_scheduled = false
    self:refresh(partial, reason)
  end)
end)

---@param reason string
---@param wait number? Milliseconds to wait before refreshing. Defaults to 2 seconds
---@return fun()
function M:deferred_refresh(reason, wait)
  return function()
    -- See `announce`
    if self.announcing then
      return
    end

    vim.defer_fn(function()
      self:dispatch_refresh(nil, reason)
    end, wait or 2000)
  end
end

function M:reset()
  logger.debug("[STATUS] Resetting repo and refreshing - CWD: " .. vim.uv.cwd())
  svn.repo:reset()
  self:refresh(nil, "reset")
end

M.dispatch_reset = a.void(function(self)
  self:reset()
end)

---@return string
function M:id()
  return "StatusBuffer"
end

return M
