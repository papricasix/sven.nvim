local svn = require("sven.lib.svn")
local dates = require("sven.lib.svn.date")
local config = require("sven.config")
local popups = require("sven.popups")
local notification = require("sven.lib.notification")
local a = require("sven.lib.async")
local window = require("sven.buffers.diff.window")

local api = vim.api

---Blame, the way fugitive shows it: the file in an ordinary window and, to its left, a narrow
---window with one row per line that tells which revision last changed it:
---
---  r2 alice 2026-10-12 │ line 1
---  r3 alice 2026-10-12 │ line 2 changed
---  r2 alice 2026-10-12 │ line 3
---     uncommitted      │ a line that is not committed yet
---
---The two windows scroll and move their cursors together. Lines of the same revision that
---follow each other form a block; every other block is shaded.
---
---  local blame = require("sven.buffers.blame_view")
---  blame.open()                              -- the file of the current buffer; again to close
---  blame.open("src/main.c")                  -- relative to the working copy root, or absolute
---  blame.open("src/main.c", { revision = 42 })   -- the file as it was in r42
---
---svn has to ask the server for a blame. That happens in the background: the gutter opens
---right away and fills in once the answer is there.
local M = {}

---@class SvenBlameView
---@field path string Absolute path of the file
---@field relative string Its path relative to the working copy root
---@field root string Root of the working copy
---@field revision number|nil The revision the file is shown in. nil for the working file
---@field file_win integer
---@field file_buf integer
---@field gutter_win integer
---@field gutter_buf integer
---@field lines SvenBlameLine[]|nil What svn answered. nil while loading
---@field loading boolean
---@field closed boolean
---@field saved table<string, any> Options of the file window, to restore
---@field previous_buf integer|nil The buffer the file window showed before a file of a revision replaced it
---@field group integer
---@field task SvenTask|nil The blame that is being fetched
---@field fetch SvenTask|nil The file of a revision that is being fetched

---@type table<integer, SvenBlameView> by buffer of the file
local blames = {}

local namespace = api.nvim_create_namespace("sven-blame")

-- Options of the file window that are changed while it is blamed
local FILE_WINDOW_OPTIONS = { "scrollbind", "cursorbind", "wrap", "foldenable" }

local INITIAL_WIDTH = 24
local MAX_AUTHOR_WIDTH = 20
local LOADING = "Loading..."

---The shade of every other block is a highlight group of its own, so that it can be changed.
---It is defined here, and again after every change of the colorscheme: a colorscheme that
---clears all highlights takes it along. One that defines the group has the last word.
local function define_highlights()
  if vim.tbl_isempty(api.nvim_get_hl(0, { name = "SvenBlameShade" })) then
    api.nvim_set_hl(0, "SvenBlameShade", { link = "CursorLine" })
  end
end

---@param win integer
---@param name string
---@param value any
local function set_window_option(win, name, value)
  api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

---@param buf integer|nil Defaults to the current buffer
---@return SvenBlameView|nil blame The blame a buffer belongs to: as the file or as the gutter
function M.get(buf)
  buf = buf or api.nvim_get_current_buf()

  if blames[buf] then
    return blames[buf]
  end

  for _, blame in pairs(blames) do
    if blame.gutter_buf == buf then
      return blame
    end
  end
end

---@param buf integer|nil Defaults to the current buffer
---@return boolean whether the buffer is blamed (or is the gutter of a blame)
function M.is_open(buf)
  return M.get(buf) ~= nil
end

---Builds the rows of the gutter.
---@param lines SvenBlameLine[] One entry per line of the file
---@param count integer Number of lines of the buffer that is blamed
---@return string[] rows
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] highlights `{ row, col_start, col_end, group }`, zero-based
---@return integer[] shaded Rows (zero-based) of the blocks that are shaded
function M.format(lines, count)
  local revision_width = 0
  local author_width = 0
  for _, line in ipairs(lines) do
    if line.revision then
      revision_width = math.max(revision_width, #tostring(line.revision) + 1)
      author_width = math.max(author_width, vim.fn.strdisplaywidth(line.author or ""))
    end
  end
  revision_width = math.max(revision_width, 2)
  author_width = math.min(author_width, MAX_AUTHOR_WIDTH)

  local rows = {}
  local highlights = {}
  local shaded = {}

  local block = 0
  local previous = false

  for index = 1, count do
    local line = lines[index]
    local row = index - 1

    if not line then
      -- The buffer has more lines than the file svn looked at
      rows[index] = ""
    else
      if line.revision ~= previous then
        block = block + 1
        previous = line.revision
      end

      if line.revision then
        local revision = ("%" .. revision_width .. "s"):format("r" .. line.revision)
        local author = vim.fn.strcharpart(line.author or "", 0, author_width)
        author = author .. (" "):rep(author_width - vim.fn.strdisplaywidth(author))
        local date = dates.format(dates.parse(line.date), "%Y-%m-%d")

        rows[index] = ("%s %s %s"):format(revision, author, date)

        local author_start = #revision + 1
        local date_start = author_start + #author + 1
        table.insert(highlights, { row, 0, #revision, "SvenBlameRevision" })
        table.insert(highlights, { row, author_start, author_start + #author, "SvenBlameAuthor" })
        table.insert(highlights, { row, date_start, date_start + #date, "SvenBlameDate" })
      else
        rows[index] = (" "):rep(revision_width + 1) .. "uncommitted"
        table.insert(highlights, { row, revision_width + 1, #rows[index], "SvenBlameUncommitted" })
      end

      if block % 2 == 0 then
        table.insert(shaded, row)
      end
    end
  end

  return rows, highlights, shaded
end

---@param blame SvenBlameView
---@param rows string[]
local function set_rows(blame, rows)
  vim.bo[blame.gutter_buf].modifiable = true
  api.nvim_buf_set_lines(blame.gutter_buf, 0, -1, false, rows)
  vim.bo[blame.gutter_buf].modifiable = false
  vim.bo[blame.gutter_buf].modified = false
end

---Fills the gutter with what svn answered
---@param blame SvenBlameView
local function render(blame)
  local count = api.nvim_buf_line_count(blame.file_buf)
  local rows, highlights, shaded = M.format(blame.lines or {}, count)

  set_rows(blame, rows)

  api.nvim_buf_clear_namespace(blame.gutter_buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    local row, col_start, col_end, group = unpack(highlight)
    api.nvim_buf_set_extmark(
      blame.gutter_buf,
      namespace,
      row,
      col_start,
      { end_col = col_end, hl_group = group }
    )
  end
  for _, row in ipairs(shaded) do
    api.nvim_buf_set_extmark(blame.gutter_buf, namespace, row, 0, { line_hl_group = "SvenBlameShade" })
  end

  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(row))
  end

  if api.nvim_win_is_valid(blame.gutter_win) then
    api.nvim_win_set_width(blame.gutter_win, math.max(width + 1, 4))
  end
end

---Puts the gutter where the file window is: same top line, same cursor line
---@param blame SvenBlameView
local function align(blame)
  if not api.nvim_win_is_valid(blame.file_win) or not api.nvim_win_is_valid(blame.gutter_win) then
    return
  end

  local view = api.nvim_win_call(blame.file_win, vim.fn.winsaveview)
  api.nvim_win_call(blame.gutter_win, function()
    vim.fn.winrestview { topline = view.topline, lnum = view.lnum, col = 0 }
  end)
end

---Closes a blame: the gutter goes away and the file window gets its options back. The file of a
---revision, which was only there to be blamed, goes away as well.
---@param blame SvenBlameView|nil Defaults to the blame of the current buffer
---@param opts { keep_file: boolean? }|nil `keep_file` leaves the file of a revision in its window
function M.close(blame, opts)
  blame = blame or M.get()
  if not blame or blame.closed then
    return
  end

  blame.closed = true

  if blame.task then
    blame.task:cancel()
  end
  if blame.fetch then
    blame.fetch:cancel()
  end

  -- Nothing was opened yet
  if not blame.file_buf then
    return
  end

  blames[blame.file_buf] = nil
  pcall(api.nvim_del_augroup_by_id, blame.group)

  if api.nvim_win_is_valid(blame.file_win) then
    for name, value in pairs(blame.saved) do
      pcall(set_window_option, blame.file_win, name, value)
    end
  end

  if api.nvim_win_is_valid(blame.gutter_win) then
    if api.nvim_get_current_win() == blame.gutter_win and api.nvim_win_is_valid(blame.file_win) then
      api.nvim_set_current_win(blame.file_win)
    end

    if not pcall(api.nvim_win_close, blame.gutter_win, true) then
      -- The last window cannot be closed. It is an ordinary window from here on.
      for _, name in ipairs { "winfixbuf", "winfixwidth", "scrollbind", "cursorbind" } do
        pcall(set_window_option, blame.gutter_win, name, false)
      end
    end
  end

  if api.nvim_buf_is_valid(blame.gutter_buf) then
    pcall(api.nvim_buf_delete, blame.gutter_buf, { force = true })
  end

  if blame.revision and not (opts and opts.keep_file) then
    window.leave(blame.file_buf, blame.previous_buf)
  end
end

---Asks svn for the blame, in the background
---@param blame SvenBlameView
local function load(blame)
  if blame.task then
    blame.task:cancel()
  end

  blame.loading = true

  blame.task = a.run(function()
    local lines, err =
      svn.blame.file(blame.relative, blame.revision, { cwd = blame.root, ignore_error = true })
    a.util.scheduler()

    if blame.closed then
      return
    end

    blame.loading = false

    if lines and #lines == 0 and api.nvim_buf_line_count(blame.file_buf) > 1 then
      lines, err = nil, "svn has no blame for this file. It may be a binary file."
    end

    if not lines then
      notification.error(("Unable to blame %s\n%s"):format(blame.relative, vim.trim(err or "")))
      M.close(blame)
      return
    end

    blame.lines = lines
    render(blame)
    align(blame)
  end)
end

---@param blame SvenBlameView
---@return SvenBlameLine|nil line What svn knows about the line under the cursor
local function line_under_cursor(blame)
  if not blame.lines then
    return nil
  end

  local win = api.nvim_get_current_win()
  if win ~= blame.gutter_win and win ~= blame.file_win then
    win = blame.gutter_win
  end

  return blame.lines[api.nvim_win_get_cursor(win)[1]]
end

---@param blame SvenBlameView
---@return number|nil revision The revision of the line under the cursor. nil (and a message) when there is none
local function revision_under_cursor(blame)
  if blame.loading then
    notification.info("The blame is still loading")
    return nil
  end

  local line = line_under_cursor(blame)
  if not line or not line.revision then
    notification.info("This line is not committed yet")
    return nil
  end

  return line.revision
end

---@param blame SvenBlameView
local function set_mappings(blame)
  local status_maps = config.get_reversed_status_maps()

  ---@param keys string|string[]
  ---@param fn fun()
  local function map(keys, fn)
    for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set("n", key, fn, { buffer = blame.gutter_buf, silent = true, nowait = true })
    end
  end

  map("<cr>", function()
    local revision = revision_under_cursor(blame)
    if revision then
      -- In a tab of its own: the two windows of the blame stay as they are
      require("sven.buffers.revision_view").new(revision, { blame.relative }):open("tab")
    end
  end)

  map("q", function()
    M.close(blame)
  end)

  -- Blame the file as it was before the revision under the cursor
  map("-", function()
    local revision = revision_under_cursor(blame)
    if not revision then
      return
    end

    if revision <= 1 then
      notification.info("There is nothing before r" .. revision)
      return
    end

    local line = api.nvim_win_get_cursor(0)[1]
    M.open(blame.path, { revision = revision - 1, line = line })
  end)

  map(popups.mapping_for("DiffPopup"), function()
    local revision = revision_under_cursor(blame)
    if revision then
      require("sven.lib.svn.repository").instance(blame.root)
      popups.open("diff", function(p)
        p { revision = revision, paths = { blame.relative }, section = { name = "blame" } }
      end)()
    end
  end)

  map(popups.mapping_for("LogPopup"), function()
    require("sven.lib.svn.repository").instance(blame.root)
    popups.open("log", function(p)
      p { paths = { blame.relative }, section = { name = "blame" } }
    end)()
  end)

  map(status_maps["YankSelected"], function()
    local revision = revision_under_cursor(blame)
    if revision then
      local yank = "r" .. revision
      vim.fn.setreg('"', yank)
      pcall(vim.fn.setreg, "+", yank)
      api.nvim_echo({ { yank } }, false, {})
    end
  end)

  map(status_maps["RefreshBuffer"], function()
    load(blame)
  end)
end

---Opens the gutter next to a window and binds the two
---@param blame SvenBlameView
local function attach(blame)
  define_highlights()

  local count = api.nvim_buf_line_count(blame.file_buf)
  local view = api.nvim_win_call(blame.file_win, vim.fn.winsaveview)

  blame.gutter_buf = api.nvim_create_buf(false, true)
  vim.bo[blame.gutter_buf].buftype = "nofile"
  vim.bo[blame.gutter_buf].bufhidden = "wipe"
  vim.bo[blame.gutter_buf].swapfile = false
  vim.bo[blame.gutter_buf].filetype = "SvenBlame"
  pcall(
    api.nvim_buf_set_name,
    blame.gutter_buf,
    ("sven-blame://%s%s"):format(blame.revision and ("r" .. blame.revision .. "/") or "", blame.relative)
  )

  -- Rows for every line right away, or the windows could not scroll together while it loads
  local rows = {}
  for index = 1, count do
    rows[index] = ""
  end
  rows[view.topline] = LOADING
  rows[view.lnum] = LOADING
  set_rows(blame, rows)

  blame.gutter_win = api.nvim_open_win(blame.gutter_buf, false, {
    split = "left",
    win = blame.file_win,
    width = INITIAL_WIDTH,
  })

  for name, value in pairs {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    colorcolumn = "",
    foldenable = false,
    wrap = false,
    list = false,
    spell = false,
    cursorline = false,
    winfixwidth = true,
    winfixbuf = true,
    scrollbind = true,
    cursorbind = true,
  } do
    set_window_option(blame.gutter_win, name, value)
  end

  blame.saved = {}
  for _, name in ipairs(FILE_WINDOW_OPTIONS) do
    blame.saved[name] = api.nvim_get_option_value(name, { win = blame.file_win })
  end

  set_window_option(blame.file_win, "scrollbind", true)
  set_window_option(blame.file_win, "cursorbind", true)
  set_window_option(blame.file_win, "wrap", false)
  set_window_option(blame.file_win, "foldenable", false)

  align(blame)

  blame.group = api.nvim_create_augroup("SvenBlame" .. blame.gutter_buf, { clear = true })

  -- Closing either window takes the other half of the pair down
  api.nvim_create_autocmd("WinClosed", {
    group = blame.group,
    pattern = { tostring(blame.gutter_win), tostring(blame.file_win) },
    callback = function()
      vim.schedule(function()
        M.close(blame)
      end)
    end,
  })

  -- So does showing something else in the file window
  api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, {
    group = blame.group,
    buffer = blame.file_buf,
    callback = function()
      vim.schedule(function()
        if
          not api.nvim_win_is_valid(blame.file_win)
          or api.nvim_win_get_buf(blame.file_win) ~= blame.file_buf
        then
          M.close(blame)
        end
      end)
    end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    group = blame.group,
    buffer = blame.gutter_buf,
    callback = function()
      vim.schedule(function()
        M.close(blame)
      end)
    end,
  })

  if not blame.revision then
    -- What is written is what svn blames
    api.nvim_create_autocmd("BufWritePost", {
      group = blame.group,
      buffer = blame.file_buf,
      callback = function()
        load(blame)
      end,
    })
  end

  -- A callback that returns something true is removed by Neovim: none of these return anything
  api.nvim_create_autocmd("ColorScheme", {
    group = blame.group,
    callback = function()
      define_highlights()
    end,
  })

  set_mappings(blame)
  blames[blame.file_buf] = blame
end

---@param path string|nil
---@return string|nil absolute The file to blame
---@return string|nil err
local function resolve_path(path)
  if not path or path == "" then
    local buf = api.nvim_get_current_buf()
    local name = api.nvim_buf_get_name(buf)
    if name == "" or vim.bo[buf].buftype ~= "" then
      return nil, "The current buffer is not a file"
    end

    return vim.fs.normalize(name), nil
  end

  path = vim.fn.expand(path)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path), nil
  end

  -- Relative to the working copy root, else as typed: relative to the current directory
  local root = svn.repo.root
  if root ~= "" and vim.uv.fs_stat(vim.fs.joinpath(root, path)) then
    return vim.fs.joinpath(root, path), nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")), nil
end

---@class SvenBlameOpenOpts
---@field revision? string|number Blame the file as it was in this revision: 42, "42", "r42"
---@field line? integer Line to put the cursor on

---Blames a file: shows it in an ordinary window with the blame gutter to its left. Called for
---a file that is blamed already (or from its gutter), it closes the blame again.
---@param path string|nil Absolute path, or a path relative to the working copy root. Defaults to the file of the current buffer
---@param opts SvenBlameOpenOpts|nil
---@return SvenBlameView|nil blame nil when the blame was closed, or could not be opened
function M.open(path, opts)
  opts = opts or {}

  local revision = nil
  if opts.revision ~= nil and opts.revision ~= "" then
    revision = tonumber((tostring(opts.revision):gsub("^[rR]", "")))
    if not revision then
      notification.error(("%q is not a revision number"):format(tostring(opts.revision)))
      return nil
    end
  end

  -- From a blame, without a path: that blame is meant
  local current = M.get()
  if current and (not path or path == "") then
    if not revision then
      M.close(current)
      return nil
    end

    path = current.path
  end

  local absolute, err = resolve_path(path)
  if not absolute then
    notification.warn(err or "No file to blame")
    return nil
  end

  local root = svn.cli.wc_root(vim.fs.dirname(absolute))
  if root == "" then
    notification.error(("%s is not inside a Subversion working copy"):format(absolute))
    return nil
  end

  local real = vim.uv.fs_realpath(absolute)
  local relative = require("sven.lib.svn.repository").find(root):relpath(real or absolute)
  if not relative or relative == "." then
    notification.error(("%s is not a file of the working copy"):format(absolute))
    return nil
  end

  -- Windows and buffers are filled in when the gutter is attached
  ---@type SvenBlameView
  ---@diagnostic disable-next-line: missing-fields
  local blame = {
    path = absolute,
    relative = relative,
    root = root,
    revision = revision,
    lines = nil,
    loading = true,
    closed = false,
    saved = {},
  }

  if not revision then
    local stat = vim.uv.fs_stat(absolute)
    if not stat or stat.type ~= "file" then
      notification.error(("%s is not a file"):format(absolute))
      return nil
    end

    local buf, win = window.edit(absolute)
    if not buf or not win then
      notification.error(("Unable to open %s"):format(absolute))
      return nil
    end

    -- Blamed already: toggle it off
    if blames[buf] then
      M.close(blames[buf])
      return nil
    end

    if vim.bo[buf].modified then
      notification.warn(
        ("%s has unsaved changes. The blame is of the file as it was written."):format(relative)
      )
    end

    blame.file_buf, blame.file_win = buf, win
    if opts.line then
      pcall(api.nvim_win_set_cursor, win, { opts.line, 0 })
    end

    attach(blame)
    load(blame)

    return blame
  end

  -- A blame of the same file, started from: it is replaced. Unless it shows this very revision.
  local replaced = current and current.path == absolute and current or nil
  if replaced and replaced.revision == revision then
    M.close(replaced)
    return nil
  end

  -- The file of a revision has to be fetched first
  blame.fetch = a.run(function()
    local content, cat_err = svn.cat.file(relative, revision, { cwd = root, ignore_error = true })
    a.util.scheduler()

    if blame.closed then
      return
    end

    if not content then
      blame.closed = true
      notification.error(("Unable to read %s at r%d\n%s"):format(relative, revision, vim.trim(cat_err or "")))
      return
    end

    -- The file of the revision takes the window of the blame it replaces
    if replaced and not replaced.closed then
      if api.nvim_win_is_valid(replaced.file_win) then
        api.nvim_set_current_win(replaced.file_win)
      end

      M.close(replaced, { keep_file = true })
    end

    local buf = window.revision_buffer(revision, relative, content)
    local win, previous = window.show(buf)

    blame.file_buf, blame.file_win = buf, win
    blame.previous_buf = previous
    if opts.line then
      pcall(api.nvim_win_set_cursor, win, { math.min(opts.line, api.nvim_buf_line_count(buf)), 0 })
    end

    -- Leaving the file ends the blame, and brings back what the window showed before
    vim.keymap.set("n", "q", function()
      M.close(blame)
    end, { buffer = buf, silent = true, nowait = true, desc = "Close the blame" })

    attach(blame)
    load(blame)
  end)

  return blame
end

---Blocks until a blame has loaded. For scripts and specs: the view itself never waits.
---@param blame SvenBlameView
---@param timeout number|nil Milliseconds, 10000 by default
---@return boolean loaded
function M.wait(blame, timeout)
  return vim.wait(timeout or 10000, function()
    return blame.closed or (blame.gutter_buf ~= nil and not blame.loading)
  end, 10)
end

return M
