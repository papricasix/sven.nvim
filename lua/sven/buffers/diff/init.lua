local Buffer = require("sven.lib.buffer")
local ui = require("sven.buffers.diff.ui")
local navigation = require("sven.buffers.diff.navigation")
local config = require("sven.config")
local jump = require("sven.lib.jump")
local notification = require("sven.lib.notification")

---A read-only buffer that renders a list of diffs: a header, a summary, an overview with one
---row per file, then the diffs with foldable files and hunks.
---
---  local result = svn.diff.staged()
---  require("sven.buffers.diff")
---    .new({ header = "Staged changes", diffs = result.diffs, stats = result.stats })
---    :open()
---
---It is what the commit editor shows next to the message, and what the diff popup opens for
---everything that is more than one file in the working copy.
---@class SvenDiffBuffer
---@field buffer Buffer|nil
---@field header string
---@field diffs Diff[]
---@field stats DiffStats|nil
---@field kind WindowKind|nil
---@field root string Root of the working copy the diffs are from
---@field name string
local M = {}
M.__index = M

---@class SvenDiffBufferOpts
---@field header string What the diffs are: "Staged changes", "Changes in a.txt", ...
---@field diffs Diff[] As returned by `svn.diff.run(...).diffs`
---@field stats? DiffStats Totals. Computed from the diffs when missing
---@field kind? WindowKind How to open the buffer. Defaults to `commit_editor.staged_diff_split_kind`
---@field root? string Root of the working copy the diffs are from. Defaults to the current one
---@field name? string Name of the buffer. Defaults to "SvenDiffView"

---@param opts SvenDiffBufferOpts
---@return SvenDiffBuffer
function M.new(opts)
  local instance = {
    buffer = nil,
    header = opts.header,
    diffs = opts.diffs or {},
    stats = opts.stats,
    kind = opts.kind,
    root = opts.root or require("sven.lib.svn").repo.root,
    name = opts.name or "SvenDiffView",
  }

  return setmetatable(instance, M)
end

---Closes the buffer
function M:close()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
  end
end

---@return boolean
function M:is_open()
  return (self.buffer and self.buffer:is_visible()) == true
end

---Opens the file of the diff under the cursor in the working copy, at the line under the cursor
---@param stay boolean|nil On a row of the overview: go to the diff of that file instead of to the file
function M:visit_file(stay)
  local location = navigation.location_under_cursor(self.buffer)
  if not location then
    local file = navigation.overview_value_under_cursor(self.buffer, "OverviewFile")
    if not file then
      return
    end

    if stay then
      navigation.goto_diff(self.buffer, file)
      return
    end

    location = { file = file, old = 1, new = 1 }
  end

  if location.file == "" then
    return
  end

  if vim.startswith(location.file, "^/") then
    notification.warn(("%s is not in the working copy"):format(location.file))
    return
  end

  jump.goto_file_at(location.file, { location.new, 0 })
end

---Opens the buffer. Does nothing when there are no diffs to show.
---@param kind WindowKind|nil
---@return SvenDiffBuffer
function M:open(kind)
  if #self.diffs == 0 then
    return self
  end

  local status_maps = config.get_reversed_status_maps()
  local commit_view_maps = config.get_reversed_commit_view_maps()

  self.buffer = Buffer.create {
    name = self.name,
    filetype = "SvenDiffView",
    status_column = not config.values.disable_signs and "" or nil,
    kind = kind or self.kind or config.values.commit_editor.staged_diff_split_kind,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    autocmds = {
      -- What happens from here happens in the working copy the diffs are from
      ["BufEnter"] = function()
        if self.root ~= "" then
          require("sven.lib.svn.repository").instance(self.root)
        end
      end,
    },
    mappings = {
      n = {
        ["{"] = function()
          navigation.goto_previous_hunk_header(self.buffer)
        end,
        ["}"] = function()
          navigation.goto_next_hunk_header(self.buffer)
        end,
        ["<cr>"] = function()
          self:visit_file(true)
        end,
        [commit_view_maps["OpenFileInWorktree"]] = function()
          self:visit_file()
        end,
        [status_maps["Toggle"]] = function()
          pcall(vim.cmd, "normal! za")
        end,
        [status_maps["Close"]] = function()
          self:close()
        end,
        ["<esc>"] = function()
          self:close()
        end,
      },
    },
    render = function()
      return ui.DiffView(self.header, self.diffs, self.stats)
    end,
    after = function()
      vim.cmd("normal! zR")
      vim.wo.colorcolumn = ""
    end,
  }

  return self
end

return M
