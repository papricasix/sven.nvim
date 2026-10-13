local Buffer = require("sven.lib.buffer")
local ui = require("sven.buffers.log_view.ui")
local config = require("sven.config")
local popups = require("sven.popups")
local RevisionView = require("sven.buffers.revision_view")
local a = require("sven.lib.async")
local notification = require("sven.lib.notification")

local api = vim.api

---The log view: one row per revision, newest first. A row unfolds to the whole log message and
---the paths the revision changed.
---
---  require("sven.buffers.log_view")
---    .new({
---      entries = svn.log.list { limit = 256, verbose = true },
---      header = "Revisions in ^/trunk",
---    })
---    :open()
---@class SvenLogView
---@field entries SvenLogEntry[]
---@field header string
---@field files string[]|nil Paths the log is limited to. The revision view is limited to them as well
---@field fetch_more (fun(entries: SvenLogEntry[]): SvenLogEntry[]|nil, boolean)|nil
---@field has_more boolean Whether there is older history to load
---@field root string Root of the working copy the log was opened for
---@field buffer Buffer|nil
---@field refresh_lock Semaphore
local M = {
  ---@type SvenLogView|nil The log view that is open
  instance = nil,
}
M.__index = M

---@class SvenLogViewOpts
---@field entries SvenLogEntry[] As returned by `svn.log.list`
---@field header string Shown above the list: what the log is of
---@field files? string[] Paths the log is limited to, relative to the working copy root. Opening a revision from the log shows what it did to these paths
---@field fetch_more? fun(entries: SvenLogEntry[]): SvenLogEntry[]|nil, boolean Loads older history. Called in an async context with the entries that are shown. Returns the complete new list (nil when there is nothing new) and whether there is still more
---@field has_more? boolean Whether there is older history to load (default: whether `fetch_more` is given)
---@field root? string Root of the working copy the log is of. Defaults to the current one

---@param opts SvenLogViewOpts
---@return SvenLogView
function M.new(opts)
  local instance = {
    entries = opts.entries or {},
    header = opts.header,
    files = opts.files and #opts.files > 0 and opts.files or nil,
    fetch_more = opts.fetch_more,
    has_more = opts.fetch_more ~= nil and opts.has_more ~= false,
    root = opts.root or require("sven.lib.svn").repo.root,
    buffer = nil,
    refresh_lock = a.control.Semaphore.new(1),
  }

  setmetatable(instance, M)

  return instance
end

function M:close()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
  end

  M.instance = nil
end

---@return boolean
function M.is_open()
  return (M.instance and M.instance.buffer and M.instance.buffer:is_visible()) == true
end

---@return number|nil revision The revision under the cursor
function M:revision_under_cursor()
  local oid = self.buffer.ui:get_commit_under_cursor()
  return oid and tonumber(oid) or nil
end

---Loads older history and appends it. Must be called in an async context.
function M:load_more()
  if not self.fetch_more or not self.has_more then
    notification.info("There is no more history")
    return
  end

  local permit = self.refresh_lock:acquire()

  local count = #self.entries
  local entries, has_more = self.fetch_more(self.entries)
  a.util.scheduler()

  self.has_more = has_more == true
  if entries then
    self.entries = entries
  end

  if not entries or #entries == count then
    notification.info(self.has_more and "No further revisions found" or "There is no more history")
  end

  if self.buffer and self.buffer:is_valid() then
    self.buffer.ui:render(unpack(ui.View(self.entries, self.has_more)))
  end

  permit:forget()
end

---The environment popups are opened with
---@param revision number|nil
---@return table
function M:popup_env(revision)
  return {
    revision = revision,
    paths = self.files or {},
    section = { name = "log" },
  }
end

---Moves the cursor to the row of the next revision in a direction, folding the one it leaves
---@param key string "j" or "k"
---@param last_line integer The line to stop at
local function move_to_row(key, last_line)
  pcall(vim.cmd, "normal! zc")

  vim.cmd("normal! " .. key)
  while vim.fn.foldlevel(".") == 0 and vim.fn.line(".") ~= last_line do
    vim.cmd("normal! " .. key)
  end
end

function M:open()
  -- A log view that is open is replaced: the buffer is the same one. Its header is not.
  local previous = M.instance
  if previous and previous ~= self and previous.buffer and previous.buffer.header_win_handle then
    pcall(api.nvim_win_close, previous.buffer.header_win_handle, true)
  end

  M.instance = self
  local status_maps = config.get_reversed_status_maps()

  ---Shows the revision under the cursor in the revision view that is open, or unfolds its row
  local function peek()
    if RevisionView.is_open() then
      local revision = self:revision_under_cursor()
      if revision then
        RevisionView.instance:update(revision, self.files)
      end
    else
      pcall(vim.cmd, "normal! zo")
      vim.cmd("normal! zz")
    end
  end

  self.buffer = Buffer.create {
    name = "SvenLogView",
    filetype = "SvenLogView",
    kind = config.values.log_view.kind,
    context_highlight = false,
    header = self.header,
    scroll_header = false,
    active_item_highlight = true,
    status_column = not config.values.disable_signs and "" or nil,
    autocmds = {
      -- What happens from here happens in the working copy the log is of
      ["BufEnter"] = function()
        if self.root ~= "" then
          require("sven.lib.svn.repository").instance(self.root)
        end
      end,
    },
    mappings = {
      v = {
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          local revisions = vim.tbl_map(tonumber, self.buffer.ui:get_commits_in_selection())
          table.sort(revisions)

          local env = self:popup_env(revisions[#revisions])
          if #revisions > 1 then
            env.range = { revisions[1], revisions[#revisions] }
          end

          p(env)
        end),
      },
      n = {
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          p(self:popup_env(self:revision_under_cursor()))
        end),
        [popups.mapping_for("LogPopup")] = popups.open("log", function(p)
          p(self:popup_env(self:revision_under_cursor()))
        end),
        [popups.mapping_for("CommitPopup")] = popups.open("commit", function(p)
          p {}
        end),
        [popups.mapping_for("UpdatePopup")] = popups.open("update", function(p)
          p { revision = self:revision_under_cursor() }
        end),
        [status_maps["YankSelected"]] = function()
          local revision = self:revision_under_cursor()
          if revision then
            local yank = "r" .. revision
            vim.fn.setreg('"', yank)
            pcall(vim.fn.setreg, "+", yank)
            api.nvim_echo({ { yank } }, false, {})
          else
            api.nvim_echo({ { "" } }, false, {})
          end
        end,
        ["<esc>"] = require("sven.lib.ui.helpers").close_topmost(self),
        [status_maps["Close"]] = require("sven.lib.ui.helpers").close_topmost(self),
        [status_maps["GoToFile"]] = function()
          local revision = self:revision_under_cursor()
          if revision then
            RevisionView.new(revision, self.files):open()
          end
        end,
        [status_maps["PeekFile"]] = function()
          local revision = self:revision_under_cursor()
          if revision then
            local view = RevisionView.new(revision, self.files):open()
            view.buffer:win_call(vim.cmd, "normal! gg")

            self.buffer:focus()
          end
        end,
        [status_maps["OpenOrScrollDown"]] = function()
          local revision = self:revision_under_cursor()
          if revision then
            RevisionView.open_or_scroll_down(revision, self.files)
          end
        end,
        [status_maps["OpenOrScrollUp"]] = function()
          local revision = self:revision_under_cursor()
          if revision then
            RevisionView.open_or_scroll_up(revision, self.files)
          end
        end,
        [status_maps["PeekUp"]] = function()
          move_to_row("k", 1)
          peek()
        end,
        [status_maps["PeekDown"]] = function()
          move_to_row("j", vim.fn.line("$"))
          peek()
        end,
        ["+"] = a.void(function()
          self:load_more()
        end),
        ["<tab>"] = function()
          pcall(vim.cmd, "normal! za")
        end,
        ["j"] = function()
          if vim.v.count > 0 then
            vim.cmd("norm! " .. vim.v.count .. "j")
          else
            vim.cmd("norm! j")
          end

          while self.buffer:get_current_line()[1]:sub(1, 1) == " " do
            if vim.fn.line(".") == vim.fn.line("$") then
              break
            end

            vim.cmd("norm! j")
          end
        end,
        ["k"] = function()
          if vim.v.count > 0 then
            vim.cmd("norm! " .. vim.v.count .. "k")
          else
            vim.cmd("norm! k")
          end

          while self.buffer:get_current_line()[1]:sub(1, 1) == " " do
            if vim.fn.line(".") == 1 then
              break
            end

            vim.cmd("norm! k")
          end
        end,
      },
    },
    render = function()
      return ui.View(self.entries, self.has_more)
    end,
    after = function(buffer)
      -- First line is empty, so move cursor to second line.
      buffer:move_cursor(2)
    end,
  }

  return self
end

return M
