local Buffer = require("sven.lib.buffer")
local ui = require("sven.buffers.revision_view.ui")
local navigation = require("sven.buffers.diff.navigation")
local window = require("sven.buffers.diff.window")
local svn = require("sven.lib.svn")
local config = require("sven.config")
local popups = require("sven.popups")
local a = require("sven.lib.async")
local notification = require("sven.lib.notification")
local jump = require("sven.lib.jump")

local api = vim.api

-- Diffs are rendered until this many lines are reached. A revision that imports a whole project
-- would otherwise take the editor down with it.
local MAX_DIFF_LINES = 20000

---The revision view: the svn counterpart of Neogit's commit view. Shows one revision: who
---committed it and when, the log message, the paths it changed and the diff of every file.
---
---  local RevisionView = require("sven.buffers.revision_view")
---  RevisionView.new(42):open()                       -- or "42", "r42"
---  RevisionView.new(42, { "src/main.c" }):open("tab")  -- only what happened to src/main.c
---
---The buffer opens right away and fills in once the repository has answered, so that a slow
---server never blocks the editor. `instance.loading` tells whether it is still waiting.
---@class SvenRevisionView
---@field revision string|number The revision that is shown. A number once it is loaded
---@field item_filter string[]|nil Only these paths (and what is below them) are shown
---@field root string Root of the working copy the view was opened for
---@field prefix string|nil Where the working copy sits in the repository, e.g. "/trunk"
---@field entry SvenLogEntry|nil The log entry of the revision. nil while loading, and when loading failed
---@field paths SvenRevisionViewPath[] The changed paths that are shown
---@field diffs Diff[] The diffs that are shown
---@field repository_paths table<string, string> Where the file of a diff is in the repository: "/trunk/a.txt" for "a.txt"
---@field notes string[] Remarks shown above the diffs
---@field error string[]|nil Why the revision could not be loaded
---@field loading boolean
---@field buffer Buffer|nil
---@field generation integer Counts the loads, to tell an answer that comes too late
local M = {
  ---@type SvenRevisionView|nil The view that is open
  instance = nil,
}

---@param revision string|number
---@return string|number revision A number where possible: 42 for 42, "42" and "r42"
local function normalize_revision(revision)
  if type(revision) == "number" then
    return revision
  end

  local digits = tostring(revision):match("^%s*[rR]?(%d+)%s*$")
  return digits and tonumber(digits) or vim.trim(tostring(revision))
end

---Creates a new revision view. Nothing is loaded or shown until `open` is called.
---@param revision string|number The revision: 42, "42", "r42" (or a keyword svn understands, like "HEAD")
---@param filter? string[] Limit the changed paths and diffs to these paths: relative to the working copy root, absolute, or `^/path` in the repository
---@return SvenRevisionView
function M.new(revision, filter)
  assert(revision, "revision cannot be nil")

  local instance = {
    revision = normalize_revision(revision),
    item_filter = filter and #filter > 0 and filter or nil,
    root = svn.repo.root,
    prefix = nil,
    entry = nil,
    paths = {},
    diffs = {},
    repository_paths = {},
    notes = {},
    error = nil,
    loading = true,
    buffer = nil,
    generation = 0,
  }

  setmetatable(instance, { __index = M })

  return instance
end

---Closes the revision view
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

---@return string oid The revision that is shown, as the `oid` of log entries has it: "42". "null-oid" when the view is not open
function M.current_oid()
  if M.is_open() then
    return tostring(M.instance.revision)
  else
    return "null-oid"
  end
end

---Opens the revision view if it does not show that revision yet, runs a command in its window
---otherwise. The focus stays where it is.
---@param revision string|number
---@param filter string[]|nil
---@param cmd string Vim command to run in the window of the view
function M.open_or_run_in_window(revision, filter, cmd)
  assert(revision, "revision cannot be nil")

  if M.is_open() and tostring(M.instance.revision) == tostring(normalize_revision(revision)) then
    M.instance.buffer:win_exec(cmd)
  else
    local cw = api.nvim_get_current_win()
    M.new(revision, filter):open()
    api.nvim_set_current_win(cw)
  end
end

---@param revision string|number
---@param filter string[]? Limit the diffs to these paths
function M.open_or_scroll_down(revision, filter)
  M.open_or_run_in_window(revision, filter, "normal! " .. vim.keycode("<c-d>"))
end

---@param revision string|number
---@param filter string[]? Limit the diffs to these paths
function M.open_or_scroll_up(revision, filter)
  M.open_or_run_in_window(revision, filter, "normal! " .. vim.keycode("<c-u>"))
end

---@param lines string[]
---@return string[] The lines of an error output that say something
local function meaningful(lines)
  return vim.tbl_filter(function(line)
    return vim.trim(line) ~= ""
  end, lines)
end

---Fetches the log entry and the diff of a revision. Suspends while svn runs.
---@param revision string|number
---@param root string
---@return SvenLogEntry|nil entry
---@return Diff[] diffs
---@return boolean whole Whether the diffs name paths in the repository (the diff of `^/`) instead of paths in the working copy
---@return string[]|nil err
local function fetch(revision, root)
  local err = nil
  local function quiet(res)
    err = meaningful(res.stderr)
    return false
  end

  -- The whole revision: also what it changed outside of the working copy
  local whole = true
  local entry = svn.log.revision(revision, { path = "^/", cwd = root, hidden = true, on_error = quiet })
  if not entry then
    -- No read access to the repository root, perhaps
    whole = false
    entry = svn.log.revision(revision, { cwd = root, hidden = true, on_error = quiet })
  end

  if not entry then
    return nil, {}, whole, err or { ("Unable to load revision %s"):format(revision) }
  end

  local result =
    svn.diff.revision(entry.revision, whole and { "^/" } or nil, { cwd = root, on_error = quiet })

  return entry, result.diffs, whole, nil
end

---@param name string
---@param filter string[]
---@return boolean
local function matches(name, filter)
  for _, path in ipairs(filter) do
    if path == "." or name == path or vim.startswith(name, path .. "/") then
      return true
    end
  end

  return false
end

---Turns the filter into names as the view uses them: paths relative to the working copy root,
---`^/path` for what is outside of it.
---@param filter string[]
---@param root string
---@param prefix string|nil
---@return string[]
local function normalize_filter(filter, root, prefix)
  local repo = require("sven.lib.svn.repository").find(root)

  return vim.tbl_map(function(path)
    if vim.startswith(path, "^/") then
      return svn.log.working_copy_path(path, prefix) or path
    elseif path:sub(1, 1) == "/" then
      return repo:relpath(path) or path
    end

    return (path:gsub("/+$", ""))
  end, filter)
end

---Fills the view with what `fetch` returned
---@param entry SvenLogEntry
---@param diffs Diff[]
---@param whole boolean
function M:populate(entry, diffs, whole)
  local prefix = self.prefix

  ---@param repository_path string "/trunk/a.txt"
  ---@return string name "a.txt" inside the working copy, "^/trunk/a.txt" outside
  local function name_of(repository_path)
    return svn.log.working_copy_path(repository_path, prefix) or ("^" .. repository_path)
  end

  self.repository_paths = {}

  for _, diff in ipairs(diffs) do
    if whole then
      local repository_path = "/" .. diff.file
      diff.file = name_of(repository_path)
      self.repository_paths[diff.file] = repository_path
    elseif prefix then
      self.repository_paths[diff.file] = diff.file == "." and prefix or (prefix .. "/" .. diff.file)
    end

    for _, hunk in ipairs(diff.hunks) do
      hunk.file = diff.file
    end
  end

  local paths = vim.tbl_map(function(path)
    return vim.tbl_extend("force", path, { file = name_of(path.path) })
  end, entry.paths)

  self.notes = {}

  if self.item_filter then
    local filter = normalize_filter(self.item_filter, self.root, prefix)

    local filtered_diffs = vim.tbl_filter(function(diff)
      return matches(diff.file, filter)
    end, diffs)
    local filtered_paths = vim.tbl_filter(function(path)
      return matches(path.file, filter)
    end, paths)

    -- A file that had another name back then is not found by its present name. Showing the
    -- whole revision beats showing nothing.
    if #filtered_diffs > 0 or #filtered_paths > 0 then
      diffs, paths = filtered_diffs, filtered_paths
      table.insert(self.notes, "Limited to " .. table.concat(filter, ", "))
    end
  end

  local shown = {}
  local lines = 0
  for _, diff in ipairs(diffs) do
    if lines > MAX_DIFF_LINES then
      break
    end

    table.insert(shown, diff)
    lines = lines + #diff.lines
  end

  if #shown < #diffs then
    table.insert(self.notes, ("%d more files are not shown: the diff is too large"):format(#diffs - #shown))
  end

  self.entry = entry
  self.revision = entry.revision
  self.paths = paths
  self.diffs = shown
end

---@return Component[]
function M:view()
  return ui.RevisionView {
    revision = self.revision,
    loading = self.loading,
    error = self.error,
    entry = self.entry,
    paths = self.paths,
    diffs = self.diffs,
    notes = self.notes,
  }
end

---Loads the revision in the background and renders it once it is there
function M:load()
  self.generation = self.generation + 1
  local generation = self.generation

  self.loading = true

  a.run(function()
    local entry, diffs, whole, err = fetch(self.revision, self.root)
    local prefix = entry and svn.log.working_copy_prefix { cwd = self.root } or nil
    a.util.scheduler()

    -- Closed, or showing something else by now
    if M.instance ~= self or self.generation ~= generation then
      return
    end

    self.loading = false
    self.prefix = prefix

    if entry then
      self.error = nil
      self:populate(entry, diffs, whole)
    else
      self.entry = nil
      self.paths = {}
      self.diffs = {}
      self.error = err
    end

    if self.buffer and self.buffer:is_valid() then
      self.buffer.ui:render(unpack(self:view()))
      self.buffer:win_call(vim.cmd, "normal! zR")
    end
  end)
end

---Blocks until the revision is loaded. For scripts and specs: the view itself never waits.
---@param timeout number|nil Milliseconds, 10000 by default
---@return boolean loaded
function M:wait(timeout)
  return vim.wait(timeout or 10000, function()
    return not self.loading
  end, 10)
end

---Shows another revision in the view that is open
---@param revision string|number
---@param filter string[]? Limit the diffs to these paths
function M:update(revision, filter)
  assert(revision, "revision cannot be nil")

  self.revision = normalize_revision(revision)
  self.item_filter = filter and #filter > 0 and filter or nil
  self.entry = nil
  self.paths = {}
  self.diffs = {}
  self.notes = {}
  self.error = nil
  self.loading = true

  if self.buffer and self.buffer:is_valid() then
    self.buffer.ui:render(unpack(self:view()))
    self.buffer:win_call(vim.cmd, "normal! gg")
  end

  self:load()
end

---@param location SvenDiffLocation
---@return boolean whether the file of the location exists in the working copy
function M:in_working_copy(location)
  if location.file == "" or vim.startswith(location.file, "^/") then
    return false
  end

  return vim.uv.fs_stat(vim.fs.joinpath(self.root, location.file)) ~= nil
end

---Opens the file under the cursor in the working copy, at the line under the cursor
---@param location SvenDiffLocation
function M:visit_working_file(location)
  -- `jump` resolves the path in the current working copy
  require("sven.lib.svn.repository").instance(self.root)
  jump.goto_file_at(location.file, { location.new, 0 })
end

---Shows the file under the cursor as it was in this revision (or right before it, on a line the
---revision removed) in a scratch buffer.
---@param location SvenDiffLocation
function M:visit_file_in_revision(location)
  local repository_path = self.repository_paths[location.file]
  local shown = self.revision
  if not repository_path or type(shown) ~= "number" then
    notification.warn(("%s is not in the working copy"):format(location.file))
    return
  end

  local deleted = location.diff ~= nil and location.diff.kind == "deleted"
  local removed = deleted or (location.line ~= nil and location.line:sub(1, 1) == "-")
  local revision = removed and shown - 1 or shown
  local line = removed and location.old or location.new

  local target = "^" .. repository_path
  local content = svn.cat.file(target, revision, { peg = revision, cwd = self.root, ignore_error = true })
  a.util.scheduler()

  if not content then
    notification.warn(("Unable to read %s at r%d"):format(repository_path, revision))
    return
  end

  local buf = window.revision_buffer(revision, target, content)
  local win = window.show(buf)
  pcall(api.nvim_win_set_cursor, win, { math.max(line, 1), 0 })
  vim.cmd("normal! zz")
end

---@return string|nil file The file under the cursor, as the diffs name it
function M:file_under_cursor()
  local location = navigation.location_under_cursor(self.buffer)
  if location and location.file ~= "" then
    return location.file
  end

  local path = navigation.overview_value_under_cursor(self.buffer, "ChangedPath")
  return path and path.file or nil
end

---The environment popups are opened with
---@return table
function M:popup_env()
  local file = self:file_under_cursor()

  local paths = {}
  if file and not vim.startswith(file, "^/") then
    paths = { file }
  elseif not file and self.item_filter then
    paths = vim.tbl_filter(function(path)
      return not vim.startswith(path, "^/") and path:sub(1, 1) ~= "/"
    end, self.item_filter)
  end

  return {
    revision = type(self.revision) == "number" and self.revision or nil,
    paths = paths,
    section = { name = "revision" },
  }
end

---Opens the revision view. The revision is loaded in the background.
---@param kind? WindowKind How to open it. Defaults to `commit_view.kind`
---@return SvenRevisionView
function M:open(kind)
  kind = kind or config.values.commit_view.kind

  M.instance = self
  local status_maps = config.get_reversed_status_maps()
  local commit_view_maps = config.get_reversed_commit_view_maps()

  self.buffer = Buffer.create {
    name = "SvenRevisionView",
    filetype = "SvenRevisionView",
    kind = kind,
    status_column = not config.values.disable_signs and "" or nil,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    autocmds = {
      ["WinLeave"] = function()
        if self.buffer and self.buffer.kind == "floating" then
          self:close()
        end
      end,
      -- What happens from here happens in the working copy the revision was opened for
      ["BufEnter"] = function()
        if self.root ~= "" then
          require("sven.lib.svn.repository").instance(self.root)
        end
      end,
    },
    mappings = {
      n = {
        [commit_view_maps["OpenFileInWorktree"]] = function()
          local location = navigation.location_under_cursor(self.buffer)
          if not location then
            local file = self:file_under_cursor()
            location = file and { file = file, old = 1, new = 1 } or nil
          end

          if not location then
            return
          end

          if self:in_working_copy(location) then
            self:visit_working_file(location)
          else
            notification.warn(("%s is not in the working copy"):format(location.file))
          end
        end,
        ["<cr>"] = a.void(function()
          local location = navigation.location_under_cursor(self.buffer)
          if location then
            if self:in_working_copy(location) then
              self:visit_working_file(location)
            else
              self:visit_file_in_revision(location)
            end

            return
          end

          -- On a changed path: go to its diff
          local path = navigation.overview_value_under_cursor(self.buffer, "ChangedPath")
          if path then
            navigation.goto_diff(self.buffer, path.file)
          end
        end),
        ["{"] = function()
          navigation.goto_previous_hunk_header(self.buffer)
        end,
        ["}"] = function()
          navigation.goto_next_hunk_header(self.buffer)
        end,
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          p(self:popup_env())
        end),
        [popups.mapping_for("LogPopup")] = popups.open("log", function(p)
          p(self:popup_env())
        end),
        [status_maps["Close"]] = function()
          self:close()
        end,
        ["<esc>"] = function()
          self:close()
        end,
        [status_maps["YankSelected"]] = function()
          local yank = "r" .. tostring(self.revision)
          vim.fn.setreg('"', yank)
          pcall(vim.fn.setreg, "+", yank)
          api.nvim_echo({ { yank } }, false, {})
        end,
        [status_maps["Toggle"]] = function()
          pcall(vim.cmd, "normal! za")
        end,
      },
    },
    render = function()
      return self:view()
    end,
    after = function()
      vim.cmd("normal! zR")
    end,
  }

  if self.loading then
    self:load()
  end

  return self
end

return M
