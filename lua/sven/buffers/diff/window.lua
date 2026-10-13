local api = vim.api

---Windows and buffers for looking at files: finding a window that is fit to show a file (not
---one of sven's own), opening a working copy file in it, and building the scratch buffer that
---holds a file as it was in a revision. Used by the diff popup and the blame view.
local M = {}

---@param win integer
---@return boolean whether the window shows an ordinary buffer of the user
local function window_belongs_to_user(win)
  if not api.nvim_win_is_valid(win) then
    return false
  end

  local cfg = api.nvim_win_get_config(win)
  if cfg.relative and cfg.relative ~= "" then
    return false
  end

  local buf = api.nvim_win_get_buf(win)
  if vim.wo[win].previewwindow or vim.wo[win].winfixbuf then
    return false
  end

  local name = api.nvim_buf_get_name(buf)
  if vim.startswith(name, "sven://") then
    return true
  end

  if vim.bo[buf].buftype ~= "" then
    return false
  end

  local filetype = vim.bo[buf].filetype or ""
  return not vim.startswith(filetype, "Sven") and filetype ~= "gitcommit"
end

---@return integer[] The tab pages, the current one first, then the one that was current before it
local function ordered_tabpages()
  local current = api.nvim_get_current_tabpage()
  local order = { current }
  local added = { [current] = true }

  local previous = vim.fn.tabpagenr("#")
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not added[tab] and previous > 0 and api.nvim_tabpage_get_number(tab) == previous then
      table.insert(order, tab)
      added[tab] = true
    end
  end

  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not added[tab] then
      table.insert(order, tab)
    end
  end

  return order
end

---@return integer|nil win A window that shows an ordinary buffer: the current one if it qualifies, then the others of this tab page, then those of other tab pages
function M.find_user_window()
  local current = api.nvim_get_current_win()
  if window_belongs_to_user(current) then
    return current
  end

  for _, tab in ipairs(ordered_tabpages()) do
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if window_belongs_to_user(win) then
        return win
      end
    end
  end
end

---Focuses a window that is fit to show a file. Opens a new tab page when there is none.
---@return integer win
function M.focus_user_window()
  local win = M.find_user_window()
  if win then
    if win ~= api.nvim_get_current_win() then
      api.nvim_set_current_win(win)
    end
  else
    vim.cmd("tabnew")
  end

  return api.nvim_get_current_win()
end

---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

---@param path string Absolute path
---@return integer|nil win A window of the current tab page that shows the file
function M.window_of(path)
  path = real(path)

  local wins = { api.nvim_get_current_win() }
  vim.list_extend(wins, api.nvim_tabpage_list_wins(0))

  for _, win in ipairs(wins) do
    local buf = api.nvim_win_get_buf(win)
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].buftype == "" and real(name) == path then
      return win
    end
  end
end

---Shows a file in a window that is fit for it, and focuses that window.
---@param path string Absolute path
---@return integer|nil buf nil when the file could not be opened
---@return integer|nil win
function M.edit(path)
  local win = M.window_of(path)
  if win then
    api.nvim_set_current_win(win)
    return api.nvim_win_get_buf(win), win
  end

  M.focus_user_window()

  -- Fails when the buffer of the window has unsaved changes and cannot be hidden
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok or real(api.nvim_buf_get_name(0)) ~= real(path) then
    ok = pcall(vim.cmd, "split " .. vim.fn.fnameescape(path))
  end

  if not ok or real(api.nvim_buf_get_name(0)) ~= real(path) then
    return nil, nil
  end

  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

---@param revision string|number
---@param path string Path of the file: relative to the working copy root, or `^/path` in the repository
---@return string name "sven://r42/src/main.c"
function M.revision_buffer_name(revision, path)
  return ("sven://r%s/%s"):format(tostring(revision):gsub("^r", ""), (path:gsub("^%^/", "")))
end

---Builds a read-only scratch buffer holding a file as it was in a revision. It is named
---`sven://r<revision>/<path>` and gets its filetype from the name of the file.
---@param revision string|number
---@param path string Path of the file: relative to the working copy root, or `^/path` in the repository
---@param content string The content of the file
---@return integer buf
function M.revision_buffer(revision, path, content)
  local name = M.revision_buffer_name(revision, path)

  local buf
  for _, candidate in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(candidate) and api.nvim_buf_get_name(candidate) == name then
      buf = candidate
      break
    end
  end

  if not buf then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, name)
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true

  if content:find("\r\n", 1, true) then
    content = content:gsub("\r\n", "\n")
    vim.bo[buf].fileformat = "dos"
  end

  local lines = vim.split(content, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then
    table.remove(lines)
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = eol or content == ""

  local filetype = vim.filetype.match { filename = path, buf = buf }
  if filetype then
    vim.bo[buf].filetype = filetype
  end

  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  return buf
end

---Puts another buffer into the window that shows a scratch buffer, and wipes the scratch buffer.
---@param buf integer The scratch buffer
---@param previous integer|nil The buffer to show instead. Without a valid one the window gets an empty buffer
function M.leave(buf, previous)
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if previous and previous ~= buf and api.nvim_buf_is_valid(previous) then
      pcall(api.nvim_win_set_buf, win, previous)
    else
      pcall(api.nvim_win_call, win, function()
        vim.cmd("enew")
      end)
    end
  end

  if api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

---Shows a scratch buffer in a window that is fit to show a file, and focuses it. `q` puts the
---buffer the window showed before back.
---@param buf integer
---@return integer win
---@return integer previous The buffer the window showed before
function M.show(buf)
  local win = M.focus_user_window()
  local previous = api.nvim_win_get_buf(win)

  -- One scratch buffer after the other in the same window: `q` goes back to where it began
  local origin = vim.b[previous].sven_origin_buffer
  if origin and api.nvim_buf_is_valid(origin) then
    previous = origin
  end

  if api.nvim_win_get_buf(win) ~= buf then
    local ok = pcall(api.nvim_win_set_buf, win, buf)
    if not ok then
      vim.cmd("split")
      win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, buf)
    end
  end

  if previous ~= buf then
    vim.b[buf].sven_origin_buffer = previous
  end

  vim.keymap.set("n", "q", function()
    M.leave(buf, vim.b[buf].sven_origin_buffer)
  end, { buffer = buf, silent = true, nowait = true, desc = "Close" })

  return win, vim.b[buf].sven_origin_buffer or previous
end

return M
