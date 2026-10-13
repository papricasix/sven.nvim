local M = {}

local svn = require("sven.lib.svn")
local config = require("sven.config")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local a = require("sven.lib.async")
local inline = require("sven.buffers.diff.inline")
local window = require("sven.buffers.diff.window")
local Env = require("sven.popups.diff.env")

local api = vim.api

---@return WindowKind How diff buffers opened from the popup are shown: `diff_view.kind` of the configuration, a tab by default
local function diff_buffer_kind()
  -- Not a setting the configuration declares: it is read when it is there
  local diff_view = config.values["diff_view"]
  return type(diff_view) == "table" and diff_view.kind or "tab"
end

---Shows diffs in the diff buffer
---@param header string
---@param diffs Diff[]
---@param empty string What to say when there are no diffs
local function show_diffs(header, diffs, empty)
  a.util.scheduler()

  if #diffs == 0 then
    notification.info(empty)
    return
  end

  require("sven.buffers.diff").new({ header = header, diffs = diffs }):open(diff_buffer_kind())
end

---@param content string
---@return boolean whether the content is not text
local function is_binary(content)
  return content:sub(1, 8000):find("\0", 1, true) ~= nil
end

---@param path string
---@return string|nil The first bytes of a file
local function read_head(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local content = vim.uv.fs_read(fd, 8000, 0)
  vim.uv.fs_close(fd)

  return content
end

---@param path string Absolute path
---@return integer|nil buf The buffer of a file, if it has one
local function buffer_of(path)
  local real = vim.fs.normalize(vim.uv.fs_realpath(path) or path)

  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].buftype == "" then
      if vim.fs.normalize(vim.uv.fs_realpath(name) or name) == real then
        return buf
      end
    end
  end
end

---@param err string|nil The error output of `svn cat`
---@return boolean whether svn has no older text because the file is new: unversioned, or added and not committed yet
local function is_new_file(err)
  err = err or ""
  return err:match("no pristine version") ~= nil
    or err:match("not under version control") ~= nil
    or err:match("W155010") ~= nil
end

---@param err string|nil The error output of `svn cat`
---@return boolean whether the file did not exist in the revision that was asked for
local function is_missing_in_revision(err)
  err = err or ""
  return err:match("E195012") ~= nil or err:match("[EW]160013") ~= nil or err:match("E200009") ~= nil
end

---The diffs of a path of the working copy, for the diff buffer. Unlike `svn diff` this knows
---about unversioned and missing files.
---@param file string Path relative to the working copy root
---@param item SvenStatusItem|nil The status item of the path, when known
---@param args string[] Additional arguments for `svn diff`
---@return Diff[]
local function path_diffs(file, item, args)
  local root = svn.repo.root
  local absolute = vim.fs.joinpath(root, file)
  local stat = vim.uv.fs_stat(absolute)

  if stat and stat.type == "directory" then
    return svn.diff.working({ file }, { args = args, ignore_error = true }).diffs
  end

  if not item or item.name ~= file then
    item = nil
    for _, candidate in
      ipairs(svn.status.fetch { paths = { file }, depth = "empty", ignore_error = true } or {})
    do
      if candidate.name == file then
        item = candidate
      end
    end
  end

  if not item and stat and not svn.info.get(file, { ignore_error = true }) then
    -- A file inside an unversioned directory: svn status only reports the directory
    ---@diagnostic disable-next-line: missing-fields
    item = { name = file, absolute_path = absolute, status = "unversioned", kind = "file" }
  end

  if item and (item.status == "unversioned" or item.status == "ignored" or item.status == "missing") then
    local diff = svn.diff.for_item(item)
    return (#diff.hunks > 0 or #diff.info > 0) and { diff } or {}
  end

  return svn.diff.working({ file }, { args = args, ignore_error = true }).diffs
end

---Shows the local changes of a file: inline in the file itself when unified.nvim is installed,
---in the diff buffer otherwise. Asked for a file that shows its inline diff already, it removes
---that diff again.
---@param file string Path relative to the working copy root
---@param item SvenStatusItem|nil The status item of the file, when known
---@param args string[]|nil Additional arguments for `svn diff`, for the diff buffer
function M.working_file(file, item, args)
  local root = svn.repo.root
  local absolute = vim.fs.joinpath(root, file)
  local stat = vim.uv.fs_stat(absolute)

  if inline.available() and stat and stat.type == "file" then
    local shown = buffer_of(absolute)
    if shown and inline.is_shown(shown) then
      inline.clear(shown)
      notification.info(("Inline diff of %s cleared"):format(file))
      return
    end

    local base, err = svn.cat.file(file, "BASE", { cwd = root, ignore_error = true })
    if not base and is_new_file(err) then
      base = ""
    end

    a.util.scheduler()

    if not base then
      notification.error(("Unable to read the base of %s\n%s"):format(file, vim.trim(err or "")))
      return
    end

    if is_binary(base) or is_binary(read_head(absolute) or "") then
      notification.warn(("%s is a binary file: there is no diff to show"):format(file))
      return
    end

    local buf = window.edit(absolute)
    if not buf then
      notification.error(("Unable to open %s"):format(file))
      return
    end

    local _, changed = inline.show(buf, base, { label = "BASE", path = absolute })
    if not changed then
      notification.info(("%s has no local changes"):format(file))
    end

    return
  end

  show_diffs(
    "Changes in " .. file,
    path_diffs(file, item, args or {}),
    ("%s has no local changes"):format(file)
  )
end

---Shows what a revision did to a file: with unified.nvim the file as it was in that revision
---(in a scratch buffer named `sven://r42/path`), with the change inline; the diff buffer without
---it. Falls back to the revision view when the file is not in that revision.
---@param file string Path relative to the working copy root
---@param revision number
---@param args string[]|nil Additional arguments for `svn diff`, for the diff buffer
function M.file_at_revision(file, revision, args)
  local root = svn.repo.root
  local cat_opts = { cwd = root, ignore_error = true }

  if inline.available() then
    local content = svn.cat.file(file, revision, cat_opts)

    if content then
      local base, err = svn.cat.file(file, revision - 1, cat_opts)
      if not base and is_missing_in_revision(err) then
        -- The revision added the file
        base = ""
      end

      a.util.scheduler()

      if base and (is_binary(content) or is_binary(base)) then
        notification.warn(("%s is a binary file: there is no diff to show"):format(file))
        return
      end

      if base then
        local buf = window.revision_buffer(revision, file, content)
        window.show(buf)

        local _, changed = inline.show(buf, base, { label = "r" .. (revision - 1) })
        if not changed then
          notification.info(("r%d did not change the text of %s"):format(revision, file))
        end

        return
      end
    end
  else
    local result = svn.diff.revision(revision, { file }, { cwd = root, args = args, ignore_error = true })
    if #result.diffs > 0 then
      show_diffs(("r%d: %s"):format(revision, file), result.diffs, "")
      return
    end
  end

  -- Not there in that revision (the revision removed it, or it had another name): the revision
  -- view tells what happened
  a.util.scheduler()
  require("sven.buffers.revision_view").new(revision, { file }):open()
end

---"Do what I mean": the revision under the cursor, the file under the cursor (or the one of the
---current buffer), or everything that changed in the working copy.
---@param popup PopupData
function M.this(popup)
  local env = Env.of(popup)
  local args = popup:get_arguments()

  if env.revision and env.file then
    M.file_at_revision(env.file, env.revision, args)
  elseif env.revision then
    a.util.scheduler()
    require("sven.buffers.revision_view").new(env.revision):open()
  elseif #env.paths > 1 then
    local diffs = {}
    for _, path in ipairs(env.paths) do
      vim.list_extend(diffs, path_diffs(path, nil, args))
    end

    show_diffs(("Changes in %d paths"):format(#env.paths), diffs, "No local changes in these paths")
  elseif env.file then
    M.working_file(env.file, env.item, args)
  elseif env.section and env.section.name == "staged" then
    M.staged(popup)
  else
    M.working(popup)
  end
end

---Every local change of the working copy
---@param popup PopupData
function M.working(popup)
  local result = svn.diff.working(nil, { args = popup:get_arguments() })
  show_diffs("Changes in the working copy", result.diffs, "The working copy has no local changes")
end

---The changes of the staged files
---@param popup PopupData
function M.staged(popup)
  local result = svn.diff.staged { args = popup:get_arguments() }
  show_diffs("Staged changes", result.diffs, "Nothing is staged")
end

---@param text string
---@return string The text with the `r` of revisions like "r42" removed
local function strip_revision_prefix(text)
  local stripped = vim.trim(text):gsub("%f[%w][rR](%d+)", "%1")
  return stripped
end

---A whole revision, in the revision view
---@param popup PopupData
function M.revision(popup)
  local env = Env.of(popup)

  local revision =
    input.get_user_input("Revision", { default = env.revision and tostring(env.revision) or "HEAD" })
  if not revision then
    return
  end

  a.util.scheduler()
  require("sven.buffers.revision_view").new(strip_revision_prefix(revision)):open()
end

---What a revision did to the file the popup was opened on
---@param popup PopupData
function M.file_revision(popup)
  local env = Env.of(popup)
  if not env.file then
    notification.warn("No file to show.")
    return
  end

  local default = env.revision
  if not default then
    local info = svn.info.get(env.file, { ignore_error = true })
    default = info and info.last_changed_rev or nil
  end

  a.util.scheduler()
  local answer = input.get_user_input(
    ("Revision of %s"):format(env.file),
    { default = default and tostring(default) or nil }
  )
  if not answer then
    return
  end

  local revision = tonumber(strip_revision_prefix(answer))
  if not revision then
    notification.warn(("%q is not a revision number"):format(answer))
    return
  end

  M.file_at_revision(env.file, revision, popup:get_arguments())
end

---The difference between two revisions (or between a revision and the working copy), of the
---file the popup was opened on or of the whole working copy
---@param popup PopupData
function M.range(popup)
  local env = Env.of(popup)

  local default = "BASE:HEAD"
  if env.range then
    default = ("%d:%d"):format(math.max(env.range[1] - 1, 0), env.range[2])
  elseif env.revision then
    default = ("%d:%d"):format(math.max(env.revision - 1, 0), env.revision)
  end

  local answer = input.get_user_input(
    "Diff revisions (FROM:TO, or FROM for the difference to the working copy)",
    { default = default }
  )
  if not answer then
    return
  end

  local range = strip_revision_prefix(answer)
  local from, to = require("sven.popups.log.actions").split_range(range)
  if from == "" then
    notification.warn(("%q is not a revision range"):format(answer))
    return
  end

  local result = svn.diff.range(
    from,
    to ~= "" and to or nil,
    env.file and { env.file } or nil,
    { args = popup:get_arguments() }
  )

  local where = env.file or "the working copy"
  show_diffs(
    ("Changes %s in %s"):format(range, where),
    result.diffs,
    ("No changes %s in %s"):format(range, where)
  )
end

---Removes every inline diff sven shows
function M.clear_inline()
  local count = inline.clear_all()
  notification.info(count == 1 and "Inline diff cleared" or ("%d inline diffs cleared"):format(count))
end

return M
