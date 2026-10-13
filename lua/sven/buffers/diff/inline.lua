local api = vim.api

---Inline diffs, drawn by unified.nvim when it is installed.
---
---unified.nvim (https://github.com/axkirillov/unified.nvim) can render the difference between
---a buffer and an arbitrary base text inside that buffer: added lines highlighted, deleted
---lines as virtual lines. Sven uses that to show a working file against its BASE text, and a
---file of a revision against its predecessor. The plugin is optional: `available()` tells
---whether it is there, and callers fall back to the diff buffer when it is not.
---
---  local inline = require("sven.buffers.diff.inline")
---  if inline.available() then
---    inline.show(buf, base_text)     -- draw, and keep up to date while the buffer is edited
---    inline.is_shown(buf)            -- true
---    inline.clear(buf)               -- remove it again
---  end
local M = {}

---@class SvenInlineDiff
---@field base string The text the buffer is compared to
---@field marks boolean Whether the last render drew anything
---@field group integer Autocmd group of the buffer
---@field label string|nil What the base is, for messages: "BASE", "r41"
---@field path string|nil Working copy file whose BASE text is the base. Set for working files only

---@type table<integer, SvenInlineDiff> by buffer
local shown = {}

---@return table|nil diff The `unified.diff` module when unified.nvim is installed and offers the embedding API
local function unified()
  local ok, diff = pcall(require, "unified.diff")
  if not ok or type(diff) ~= "table" or type(diff.show_against_text) ~= "function" then
    return nil
  end

  -- The namespace and the highlight groups of unified.nvim are created by its setup. Someone
  -- who installed it without calling setup gets its defaults. Looked at every time: the plugin
  -- may have been reloaded.
  local config_ok, config = pcall(require, "unified.config")
  if not config_ok or type(config) ~= "table" then
    return nil
  end

  if not config.ns_id then
    local setup_ok = pcall(config.setup, config.user)
    if not setup_ok or not config.ns_id then
      return nil
    end
  end

  return diff
end

---@return boolean whether inline diffs can be drawn: unified.nvim is installed
function M.available()
  return unified() ~= nil
end

---Makes the base text comparable to the lines of a buffer: Neovim keeps lines without their
---line endings, without a byte order mark, and converted to UTF-8.
---@param buf integer
---@param base string
---@return string
local function normalize(buf, base)
  if vim.bo[buf].bomb and base:sub(1, 3) == "\239\187\191" then
    base = base:sub(4)
  end

  local encoding = vim.bo[buf].fileencoding
  if encoding ~= "" and encoding ~= "utf-8" then
    local converted = vim.iconv(base, encoding, "utf-8")
    if converted then
      base = converted
    end
  end

  local format = vim.bo[buf].fileformat
  if format == "dos" then
    base = base:gsub("\r\n", "\n")
  elseif format == "mac" then
    base = base:gsub("\r", "\n")
  end

  return base
end

---Removes what unified.nvim drew in a buffer
---@param buf integer
local function erase(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  local ok, config = pcall(require, "unified.config")
  if ok and config.ns_id then
    api.nvim_buf_clear_namespace(buf, config.ns_id, 0, -1)
  end

  pcall(vim.fn.sign_unplace, "unified_diff", { buffer = buf })

  local store_ok, hunk_store = pcall(require, "unified.hunk_store")
  if store_ok and type(hunk_store.clear) == "function" then
    pcall(hunk_store.clear, buf)
  end
end

---@param buf integer
---@return boolean drawn Whether there is something to see
local function render(buf)
  local state = shown[buf]
  local diff = unified()
  if not state or not diff then
    return false
  end

  local ok, err = pcall(diff.show_against_text, buf, state.base)
  if not ok then
    require("sven.logger").error("[INLINE DIFF] unified.nvim failed: " .. tostring(err))
    return false
  end

  state.marks = diff.is_diff_displayed(buf)
  return state.marks
end

---@param buf integer
local function forget(buf)
  local state = shown[buf]
  if state then
    pcall(api.nvim_del_augroup_by_id, state.group)
    shown[buf] = nil
  end
end

---Redraws after the buffer changed. Someone who removed the marks with `:Unified reset` wanted
---them gone: the diff is not drawn again then.
---@param buf integer
---@param reloaded boolean|nil The buffer was read from its file again, which takes the marks along: no one reset them
local function refresh(buf, reloaded)
  local state = shown[buf]
  local diff = unified()
  if not state or not diff then
    return
  end

  if state.marks and not reloaded and not diff.is_diff_displayed(buf) then
    forget(buf)
    return
  end

  render(buf)
end

---Reads the BASE text of the working files that show an inline diff again, and redraws them.
---Runs in the background.
function M.reload_bases()
  local a = require("sven.lib.async")
  local svn = require("sven.lib.svn")

  for buf, state in pairs(shown) do
    if state.path then
      a.run(function()
        local base = svn.cat.file(state.path, "BASE", { ignore_error = true })
        a.util.scheduler()

        if base and shown[buf] == state then
          M.rebase(buf, base)
        end
      end)
    end
  end
end

local watching = false

---A commit turns the committed text into the BASE text: nothing is left to show for that file.
---An update brings a new BASE text as well.
local function watch_commits()
  if watching then
    return
  end
  watching = true

  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("SvenInlineDiffBase", { clear = true }),
    pattern = { "SvenCommitComplete", "SvenUpdateComplete" },
    callback = function()
      M.reload_bases()
    end,
  })
end

---@class SvenInlineOpts
---@field label? string What the base is, for messages: "BASE", "r41"
---@field path? string For a working file: its absolute path. The diff then follows the BASE text of the file, which a commit changes
---@field jump? boolean Move the cursor of the window showing the buffer to the first change (default true)

---Draws the difference between a buffer and a base text into the buffer, and keeps it up to
---date while the buffer is edited.
---@param buf integer
---@param base string The text to compare to, as stored: line endings and encoding are adapted to the buffer
---@param opts SvenInlineOpts|nil
---@return boolean ok false when unified.nvim is not available
---@return boolean changed Whether the buffer differs from the base
function M.show(buf, base, opts)
  opts = opts or {}

  if not unified() or not api.nvim_buf_is_valid(buf) then
    return false, false
  end

  forget(buf)

  local group = api.nvim_create_augroup("SvenInlineDiff" .. buf, { clear = true })
  shown[buf] = {
    base = normalize(buf, base),
    marks = false,
    group = group,
    label = opts.label,
    path = opts.path,
  }

  -- None of these callbacks returns anything: Neovim removes an autocmd whose callback
  -- returns something true, and all of them have to fire again and again.
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    group = group,
    buffer = buf,
    callback = function()
      refresh(buf)
    end,
  })

  -- The file changed on disk (an update, a revert), or was read again with `:edit`
  api.nvim_create_autocmd({ "FileChangedShellPost", "BufReadPost" }, {
    group = group,
    buffer = buf,
    callback = function()
      refresh(buf, true)
    end,
  })

  -- Deleted lines are wrapped for the width the window had when they were drawn
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      local diff = unified()
      if shown[buf] and diff and type(diff.rerender) == "function" then
        pcall(diff.rerender, buf)
      end
    end,
  })

  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      forget(buf)
    end,
  })

  if opts.path then
    watch_commits()
  end

  local changed = render(buf)

  if changed and opts.jump ~= false then
    local win = vim.fn.bufwinid(buf)
    local ok, navigation = pcall(require, "unified.navigation")
    if win ~= -1 and ok and type(navigation.jump_to_first_hunk) == "function" then
      pcall(navigation.jump_to_first_hunk, win, buf)
    end
  end

  return true, changed
end

---@param buf integer|nil Defaults to the current buffer
---@return boolean whether sven shows an inline diff in the buffer
function M.is_shown(buf)
  buf = buf or api.nvim_get_current_buf()
  return shown[buf] ~= nil
end

---@return integer[] The buffers sven shows an inline diff in
function M.buffers()
  local buffers = vim.tbl_keys(shown)
  table.sort(buffers)

  return buffers
end

---@param buf integer|nil Defaults to the current buffer
---@return SvenInlineDiff|nil
function M.get(buf)
  return shown[buf or api.nvim_get_current_buf()]
end

---Removes the inline diff of a buffer
---@param buf integer|nil Defaults to the current buffer
---@return boolean cleared false when there was none
function M.clear(buf)
  buf = buf or api.nvim_get_current_buf()
  if not shown[buf] then
    return false
  end

  forget(buf)
  erase(buf)

  return true
end

---Removes every inline diff sven shows
---@return integer count How many there were
function M.clear_all()
  local buffers = M.buffers()
  for _, buf in ipairs(buffers) do
    M.clear(buf)
  end

  return #buffers
end

---Replaces the base text of a buffer that shows an inline diff, and redraws it
---@param buf integer
---@param base string
function M.rebase(buf, base)
  local state = shown[buf]
  if not state or not api.nvim_buf_is_valid(buf) then
    return
  end

  state.base = normalize(buf, base)
  -- A diff that vanishes because the buffer now equals its base was not reset by the user
  state.marks = false
  render(buf)
end

return M
