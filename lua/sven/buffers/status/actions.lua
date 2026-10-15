-- NOTE: `v_` prefix stands for visual mode actions, `n_` for normal mode.
--
-- A port of Neogit's `buffers/status/actions.lua`. Where git stages hunks and lines, Subversion
-- can only tell whole files apart (by changelist), so staging acts on files. Discarding does
-- work on hunks and lines, through `svn patch --reverse-diff`.
local a = require("sven.lib.async")
local svn = require("sven.lib.svn")
local popups = require("sven.popups")
local logger = require("sven.logger")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local util = require("sven.lib.util")
local jump = require("sven.lib.jump")
local display_name = require("sven.buffers.status.ui").display_name

local fn = vim.fn
local api = vim.api

---@param item table|nil
---@return boolean Whether this is an item of `svn status` (and not a log entry)
local function is_status_item(item)
  return type(item) == "table" and item.status ~= nil and item.name ~= nil
end

---@param section string|nil Name of a section
---@return boolean Whether its items can be staged
local function is_stageable(section)
  return section == "unversioned"
    or section == "changes"
    or section == "conflicts"
    or (section ~= nil and vim.startswith(section, "changelist:"))
end

---@param section string|nil Name of a section
---@return boolean Whether the section lists files (and not log entries)
local function lists_files(section)
  return section == "staged" or is_stageable(section)
end

---@param items SvenStatusItem[]
---@return string[]
local function names(items)
  return util.map(items, function(item)
    return item.name
  end)
end

---@param items SvenStatusItem[]
---@return string[] What a partial refresh needs to know: the items whose diff is stale
local function stale_diffs(items)
  return util.map(items, function(item)
    return "*:" .. item.name
  end)
end

---@param item SvenStatusItem
---@return string One line for a list of items: "modified  src/main.c"
local function describe(item)
  local mode = require("sven.config").values.status.mode_text[item.mode]
  if not mode or mode == "" then
    mode = item.status
  end

  return ("%s  %s"):format(util.pad_right(mode, 11), display_name(item))
end

---@param items SvenStatusItem[]
---@return string One indented line per item, the long tail summarized
local function list(items)
  local lines = {}
  for i, item in ipairs(items) do
    if i > 10 then
      table.insert(lines, ("  ... and %d more"):format(#items - 10))
      break
    end

    table.insert(lines, "  " .. describe(item))
  end

  return table.concat(lines, "\n")
end

---Loads a module another part of the plugin provides. Tells the user when that fails, instead
---of raising.
---@param module string
---@param label string What the module is, for the notification: "revision view"
---@return table|nil
local function optional(module, label)
  local ok, result = pcall(require, module)
  if ok and type(result) == "table" then
    return result
  end

  if not ok and tostring(result):match("module '" .. vim.pesc(module) .. "' not found") then
    notification.warn(("The %s is not available"):format(label))
  else
    notification.error(("Failed to load the %s:\n%s"):format(label, tostring(result)))
  end

  return nil
end

---Calls into a module another part of the plugin provides. Tells the user when that fails,
---instead of raising.
---@param label string What is being called, for the notification: "revision view"
---@param f function
---@param ... any Arguments of `f`
---@return any|nil result The first return value of `f`, nil when it raised
local function guarded(label, f, ...)
  local ok, result = pcall(f, ...)
  if ok then
    return result
  end

  logger.error(("[STATUS] The %s failed: %s"):format(label, tostring(result)))
  notification.error(("The %s failed:\n%s"):format(label, tostring(result)))

  return nil
end

---@return table|nil The revision view (the counterpart of Neogit's commit view)
local function revision_view()
  return optional("sven.buffers.revision_view", "revision view")
end

---The line of the working file that corresponds to the line of a hunk the cursor is on.
---@param self StatusBuffer
---@param item SvenStatusItem
---@return integer[]|nil
local function translate_cursor_location(self, item)
  local line = self.buffer:cursor_line()

  -- The cursor is inside a diff, which has been loaded in order to be shown
  if rawget(item, "diff") and item.first and line > item.first then
    for _, hunk in ipairs(item.diff.hunks) do
      if hunk.first and line >= hunk.first and line <= hunk.last then
        local offset = line - hunk.first
        local row = jump.adjust_row(hunk.disk_from, offset, hunk.lines, "-")
        return { row, 0 }
      end
    end
  end
end

---@param type string A command that opens a file: "edit", "split", "vsplit", "tabedit"
---@param path string
---@param cursor integer[]|nil
local function open(type, path, cursor)
  jump.open(type, path, cursor, "[Status - Open]")
end

---@param item SvenStatusItem
---@return boolean Whether the item can be opened. The user has been told if not
local function openable(item)
  if vim.uv.fs_lstat(item.absolute_path) then
    return true
  end

  notification.info(("%s is %s: there is nothing to open"):format(item.name, item.status))
  return false
end

---Wipes the buffers of paths that are gone from disk, unless they have unsaved changes.
---@param items SvenStatusItem[]
local function wipe_buffers(items)
  for _, item in ipairs(items) do
    if not vim.uv.fs_lstat(item.absolute_path) then
      local prefix = item.absolute_path .. "/"

      for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if name == item.absolute_path or vim.startswith(name, prefix) then
          pcall(api.nvim_buf_delete, buf, { force = false })
        end
      end
    end
  end
end

---How far a revert of an item reaches. `svn revert` is recursive unless told otherwise, which
---is right for a directory that was added or deleted as a whole. A directory that is listed for
---a change of its own (properties, a conflict) must not take its children with it.
---@param item SvenStatusItem
---@return boolean shallow
local function reverts_shallow(item)
  if item.kind ~= "dir" then
    return false
  end

  local whole_tree = { added = true, deleted = true, replaced = true, missing = true }
  return not whole_tree[item.text_status]
end

---@param item SvenStatusItem
---@return string What to ask before the item is discarded
local function discard_question(item)
  local name = display_name(item)
  local dir = item.kind == "dir"

  if item.status == "unversioned" then
    if dir then
      return ("Delete the unversioned directory %q and everything in it?"):format(name)
    end

    return ("Delete the unversioned file %q?"):format(name)
  end

  if item.conflicted then
    return ("Discard all local changes to %q and drop its conflict?"):format(name)
  end

  if item.status == "added" then
    if dir then
      return ("Undo the addition of %q and everything in it? The files stay on disk, unversioned."):format(
        name
      )
    end

    return ("Undo the addition of %q? The file stays on disk, unversioned."):format(name)
  elseif item.status == "deleted" then
    return ("Undo the deletion of %q?"):format(name)
  elseif item.status == "missing" then
    return ("Restore the missing %q?"):format(name)
  elseif item.status == "replaced" then
    return ("Undo the replacement of %q?"):format(name)
  end

  local text_changed = item.text_status ~= "normal" and item.text_status ~= "none"
  if item.props == "modified" and not text_changed then
    return ("Discard the property changes of %q?"):format(name)
  elseif item.props == "modified" then
    return ("Discard all changes to %q, including its properties?"):format(name)
  end

  return ("Discard all changes to %q?"):format(name)
end

---@param item SvenStatusItem
---@return string|nil Why no hunk of the item can be discarded. nil when it can
local function hunk_refusal(item)
  if item.status == "modified" or item.status == "conflicted" then
    return nil
  end

  local name = display_name(item)
  local reasons = {
    unversioned = "%s is unversioned, as a whole. Discard the file to delete it.",
    added = "%s is added, as a whole. Discard the file to undo the addition.",
    deleted = "%s is deleted, as a whole. Discard the file to restore it.",
    missing = "%s is missing, as a whole. Discard the file to restore it.",
    replaced = "%s is replaced, as a whole. Discard the file to undo the replacement.",
  }

  return (reasons[item.status] or "The changes of %s can only be discarded as a whole."):format(name)
end

---A hunk, or some lines of it
---@class SvenHunkSelection
---@field item SvenStatusItem
---@field hunk Hunk
---@field from number|nil First selected line, 1-based offset into `hunk.lines`. nil for the whole hunk
---@field to number|nil Last selected line

---The parts of the hunks of an item that a range of buffer lines covers.
---@param item SvenStatusItem An item whose diff is shown
---@param first_line number
---@param last_line number
---@return SvenHunkSelection[] Only hunks in which the range covers at least one changed line
local function selected_hunks(item, first_line, last_line)
  local selections = {}

  for _, hunk in ipairs(item.diff.hunks) do
    if hunk.first and hunk.first <= last_line and hunk.last >= first_line then
      local from = math.max(first_line - hunk.first, 1)
      local to = math.min(last_line - hunk.first, hunk.length)

      local changes = false
      for i = from, to do
        local operand = hunk.lines[i]:sub(1, 1)
        changes = changes or operand == "+" or operand == "-"
      end

      -- A selection of the hunk header alone means the hunk
      if first_line == hunk.first and last_line == hunk.first then
        table.insert(selections, { item = item, hunk = hunk })
      elseif changes then
        local whole = from == 1 and to == hunk.length
        table.insert(selections, {
          item = item,
          hunk = hunk,
          from = not whole and from or nil,
          to = not whole and to or nil,
        })
      end
    end
  end

  return selections
end

---What a discard is going to do
---@class SvenDiscardPlan
---@field unversioned SvenStatusItem[] Deleted from disk
---@field reverted SvenStatusItem[] Reverted, recursively
---@field reverted_shallow SvenStatusItem[] Directories of which only their own changes are reverted
---@field hunks SvenHunkSelection[] Removed from their working file

---@return SvenDiscardPlan
local function discard_plan()
  return { unversioned = {}, reverted = {}, reverted_shallow = {}, hunks = {} }
end

---@param plan SvenDiscardPlan
---@param item SvenStatusItem
local function plan_item(plan, item)
  if item.status == "unversioned" then
    table.insert(plan.unversioned, item)
  elseif reverts_shallow(item) then
    table.insert(plan.reverted_shallow, item)
  else
    table.insert(plan.reverted, item)
  end
end

---@param plan SvenDiscardPlan
---@return SvenStatusItem[] Every item the plan discards as a whole
local function planned_items(plan)
  return util.merge(plan.unversioned, plan.reverted, plan.reverted_shallow)
end

---Carries out a discard and refreshes the buffer.
---@param self StatusBuffer
---@param plan SvenDiscardPlan
---@param reason string For the log
local function discard(self, plan, reason)
  local touched = planned_items(plan)

  -- From the bottom of a file to its top: removing lines must not move the hunks still to come
  table.sort(plan.hunks, function(left, right)
    if left.item.name ~= right.item.name then
      return left.item.name < right.item.name
    end

    return left.hunk.disk_from > right.hunk.disk_from
  end)

  for _, selection in ipairs(plan.hunks) do
    logger.debug(("[STATUS] Discarding a hunk of %q"):format(selection.item.name))
    svn.revert.hunk(selection.item, selection.hunk, { from = selection.from, to = selection.to })
    table.insert(touched, selection.item)
  end

  if #plan.unversioned > 0 then
    svn.revert.unversioned(names(plan.unversioned))
    wipe_buffers(plan.unversioned)
  end

  if #plan.reverted > 0 then
    svn.revert.files(names(plan.reverted))
  end

  if #plan.reverted_shallow > 0 then
    svn.revert.files(names(plan.reverted_shallow), { depth = "empty" })
  end

  local reverted = util.merge(names(plan.reverted), names(plan.reverted_shallow))
  for _, selection in ipairs(plan.hunks) do
    table.insert(reverted, selection.item.name)
  end

  if #reverted > 0 then
    self:announce("RevertComplete", { paths = util.deduplicate(reverted) })
  end

  self:dispatch_refresh({ update_diffs = stale_diffs(touched) }, reason)
end

---Stages items, and resolves the conflicted ones among them as they are.
---@param self StatusBuffer
---@param items SvenStatusItem[]
---@param reason string For the log
local function stage(self, items, reason)
  local conflicted = {}
  local others = {}

  for _, item in ipairs(items) do
    if item.conflicted then
      table.insert(conflicted, item)
    else
      table.insert(others, item)
    end
  end

  if #others > 0 then
    svn.changelist.stage(names(others))
  end

  -- A conflicted file that is staged is one that has been dealt with: "resolved, ready to commit"
  if #conflicted > 0 then
    require("sven.popups.resolve.actions").resolve(conflicted, "working", { stage = true })
  end

  self:dispatch_refresh({ update_diffs = stale_diffs(items) }, reason)
end

---Says that whole files were (un)staged where only a part of them was asked for.
---@param verb string "stage" or "unstage"
---@param items SvenStatusItem[] Files of which only a part was asked for
local function notify_whole_files(verb, items)
  if #items == 0 then
    return
  end

  local what = #items == 1 and ("all of " .. items[1].name) or ("%d files as a whole"):format(#items)
  notification.info(
    ("%s%sd %s: Subversion cannot %s parts of a file"):format(verb:sub(1, 1):upper(), verb:sub(2), what, verb)
  )
end

---The context a popup is opened in: what the cursor (or the visual selection) is on.
---@class SvenPopupEnv
---@field item SvenStatusItem|nil The item under the cursor
---@field section { name: string }|nil The section under the cursor: "conflicts", "unversioned", "changes", "staged", "changelist:<name>" or "recent"
---@field revision number|nil The revision of the log entry under the cursor
---@field paths string[] Paths (relative to the working copy root) of every item under the cursor or in the selection

---@param self StatusBuffer
---@return SvenPopupEnv
local function popup_env(self)
  local ui = self.buffer.ui
  local selection = ui:get_selection()

  local paths = {}
  for _, item in ipairs(selection.items) do
    if is_status_item(item) then
      table.insert(paths, item.name)
    end
  end

  local commit = ui:get_commit_under_cursor()

  return {
    item = is_status_item(selection.item) and selection.item or nil,
    section = selection.section and { name = selection.section.name } or nil,
    revision = commit and tonumber(commit) or nil,
    paths = util.deduplicate(paths),
  }
end

---@param self StatusBuffer
---@param name string Name of a popup
---@return fun()
local function popup(self, name)
  return popups.open(name, function(p)
    p(popup_env(self))
  end)
end

---Splits a command line into words, honouring quotes and backslashes like a shell does.
---@param line string
---@return string[]
local function split_command(line)
  local words = {}
  local word = nil
  local quote = nil
  local i = 1

  while i <= #line do
    local char = line:sub(i, i)

    if quote then
      if char == quote then
        quote = nil
      elseif char == "\\" and quote == '"' and i < #line then
        i = i + 1
        word = word .. line:sub(i, i)
      else
        word = word .. char
      end
    elseif char == '"' or char == "'" then
      quote = char
      word = word or ""
    elseif char == "\\" and i < #line then
      i = i + 1
      word = (word or "") .. line:sub(i, i)
    elseif char:match("%s") then
      if word then
        table.insert(words, word)
        word = nil
      end
    else
      word = (word or "") .. char
    end

    i = i + 1
  end

  if word then
    table.insert(words, word)
  end

  return words
end

local M = {}

M.split_command = split_command

---@param self StatusBuffer
---@return fun(): nil
M.v_discard = function(self)
  return a.void(function()
    local ui = self.buffer.ui
    local selection = ui:get_selection()

    local plan = discard_plan()
    local refusals = {}

    for _, section in ipairs(selection.sections) do
      if lists_files(section.name) then
        for _, item in ipairs(section.items) do
          -- A selection that starts below the name of a file is about lines of its diff
          local inside_diff = not item.folded and selection.first_line > item.first

          if inside_diff then
            local refusal = hunk_refusal(item)
            if refusal then
              table.insert(refusals, refusal)
            else
              vim.list_extend(plan.hunks, selected_hunks(item, selection.first_line, selection.last_line))
            end
          else
            plan_item(plan, item)
          end
        end
      end
    end

    if #refusals > 0 then
      notification.warn(table.concat(refusals, "\n"))
    end

    local items = planned_items(plan)
    if #items == 0 and #plan.hunks == 0 then
      if #refusals == 0 then
        notification.info("The selection contains nothing to discard")
      end
      return
    end

    local message
    if #items == 0 then
      local files = util.deduplicate(util.map(plan.hunks, function(selection)
        return selection.item.name
      end))

      local partial = false
      for _, selection in ipairs(plan.hunks) do
        partial = partial or selection.from ~= nil
      end

      message = ("Discard the selected %s of %s?"):format(
        partial and "lines" or (#plan.hunks == 1 and "hunk" or "hunks"),
        #files == 1 and ("%q"):format(files[1]) or ("%d files"):format(#files)
      )
    elseif #items == 1 and #plan.hunks == 0 then
      message = discard_question(items[1])
    else
      message = ("Discard these %d items%s?\n%s"):format(
        #items,
        #plan.hunks > 0 and " and the selected lines" or "",
        list(items)
      )
    end

    if input.get_permission(message) then
      discard(self, plan, "v_discard")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_stage = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local items = {}
    local partial = {}

    for _, section in ipairs(selection.sections) do
      if is_stageable(section.name) then
        for _, item in ipairs(section.items) do
          table.insert(items, item)

          if not item.folded and selection.first_line > item.first then
            table.insert(partial, item)
          end
        end
      end
    end

    if #items > 0 then
      notify_whole_files("stage", partial)
      stage(self, items, "v_stage")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_unstage = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local items = {}
    local partial = {}

    for _, section in ipairs(selection.sections) do
      if section.name == "staged" then
        for _, item in ipairs(section.items) do
          table.insert(items, item)

          if not item.folded and selection.first_line > item.first then
            table.insert(partial, item)
          end
        end
      end
    end

    if #items > 0 then
      notify_whole_files("unstage", partial)
      svn.changelist.unstage(names(items))
      self:dispatch_refresh({ update_diffs = stale_diffs(items) }, "v_unstage")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_yank_selected = function(self)
  return function()
    local ui = self.buffer.ui
    local first, last = fn.line("v"), fn.line(".")
    if first > last then
      first, last = last, first
    end

    local yanked = {}
    for line = first, last do
      local component = ui:get_component_on_line(line, function(node)
        return node.options.yankable ~= nil
      end)

      if component then
        table.insert(yanked, component.options.yankable)
      end
    end

    M.yank(table.concat(util.deduplicate(yanked), "\n"))
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.v_help_popup = function(self)
  return popup(self, "help")
end

---@param self StatusBuffer
---@return fun(): nil
M.v_commit_popup = function(self)
  return popup(self, "commit")
end

---@param self StatusBuffer
---@return fun(): nil
M.v_log_popup = function(self)
  return popup(self, "log")
end

---@param self StatusBuffer
---@return fun(): nil
M.v_diff_popup = function(self)
  return popup(self, "diff")
end

---@param self StatusBuffer
---@return fun(): nil
M.v_update_popup = function(self)
  return popup(self, "update")
end

---@param self StatusBuffer
---@return fun(): nil
M.v_resolve_popup = function(self)
  return popup(self, "resolve")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_down = function(self)
  return function()
    if vim.v.count > 0 then
      vim.cmd("norm! " .. vim.v.count .. "j")
    else
      vim.cmd("norm! j")
    end

    if self.buffer:get_current_line()[1] == "" then
      vim.cmd("norm! j")
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_up = function(self)
  return function()
    if vim.v.count > 0 then
      vim.cmd("norm! " .. vim.v.count .. "k")
    else
      vim.cmd("norm! k")
    end

    if self.buffer:get_current_line()[1] == "" then
      vim.cmd("norm! k")
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_toggle = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      if fold.options.on_open then
        fold.options.on_open(fold, self.buffer.ui)
      else
        local start, _ = fold:row_range_abs()
        local ok, _ = pcall(vim.cmd, "normal! za")
        if ok then
          self.buffer:move_cursor(start)
          fold.options.folded = not fold.options.folded
        end
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_fold = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      if fold.options.on_open then
        fold.options.on_open(fold, self.buffer.ui)
      else
        local start, _ = fold:row_range_abs()
        local ok, _ = pcall(vim.cmd, "normal! zo")
        if ok then
          self.buffer:move_cursor(start)
          fold.options.folded = false
        end
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_close_fold = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      local start, _ = fold:row_range_abs()
      local ok, _ = pcall(vim.cmd, "normal! zc")
      if ok then
        self.buffer:move_cursor(start)
        fold.options.folded = true
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_close = function(self)
  return require("sven.lib.ui.helpers").close_topmost(self)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_or_scroll_down = function(self)
  return function()
    local commit = self.buffer.ui:get_commit_under_cursor()
    if commit then
      local view = revision_view()
      if view then
        guarded("revision view", view.open_or_scroll_down, commit)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_or_scroll_up = function(self)
  return function()
    local commit = self.buffer.ui:get_commit_under_cursor()
    if commit then
      local view = revision_view()
      if view then
        guarded("revision view", view.open_or_scroll_up, commit)
      end
    end
  end
end

---Shows a revision in the revision view, leaving the cursor in the status buffer.
---@param self StatusBuffer
---@param commit string
local function peek_revision(self, commit)
  local view = revision_view()
  if not view then
    return
  end

  guarded("revision view", function()
    view.new(commit):open()
  end)

  self.buffer:focus()
end

---Moves to the neighbouring item and shows it: the diff of a file is unfolded (and the one that
---was left is folded again), a revision is shown in the revision view if that is open.
---@param self StatusBuffer
---@param direction integer 1 for down, -1 for up
local function peek(self, direction)
  local ui = self.buffer.ui
  local has_item = function(node)
    return node.options.item ~= nil
  end

  local current = ui:get_component_under_cursor(has_item)
  local line = fn.line(".")
  local target

  if current then
    local first, last = current:row_range_abs()
    line = direction > 0 and last or first
  end

  for candidate = line + direction, direction > 0 and fn.line("$") or 1, direction do
    local component = ui:get_component_on_line(candidate, has_item)
    if component and component ~= current then
      target = component
      break
    end
  end

  if not target then
    return
  end

  -- Fold what is left behind
  if current and current.options.foldable and not current.options.folded then
    local first, _ = current:row_range_abs()
    self.buffer:move_cursor(first)
    if pcall(vim.cmd, "normal! zc") then
      current.options.folded = true
    end
  end

  local first, _ = target:row_range_abs()
  self.buffer:move_cursor(first)

  if target.options.oid then
    local view = revision_view()
    if view and view.is_open and view.is_open() then
      peek_revision(self, target.options.oid)
    end
  elseif target.options.foldable then
    if target.options.on_open then
      target.options.on_open(target, ui)
    elseif target.options.folded and pcall(vim.cmd, "normal! zo") then
      target.options.folded = false
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_peek_down = function(self)
  return function()
    peek(self, 1)
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_peek_up = function(self)
  return function()
    peek(self, -1)
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_refresh_buffer = function(self)
  return a.void(function()
    -- Someone else may have committed: ask the server for the log again
    svn.repo:invalidate_recent()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_refresh_buffer")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth1 = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    if section then
      local start, last = section:row_range_abs()
      if self.buffer:cursor_line() < start or self.buffer:cursor_line() >= last then
        return
      end

      self.buffer:move_cursor(start)
      section:close_all_folds(self.buffer.ui)

      self.buffer.ui:update()
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth2 = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    local row = self.buffer.ui:get_component_under_cursor()

    if section then
      local start, last = section:row_range_abs()
      if self.buffer:cursor_line() < start or self.buffer:cursor_line() >= last then
        return
      end

      self.buffer:move_cursor(start)

      section:close_all_folds(self.buffer.ui)
      section:open_all_folds(self.buffer.ui, 1)

      self.buffer.ui:update()

      if row then
        local start, _ = row:row_range_abs()
        self.buffer:move_cursor(start)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth3 = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    local context = self.buffer.ui:get_cursor_context()

    if section then
      local start, last = section:row_range_abs()
      if self.buffer:cursor_line() < start or self.buffer:cursor_line() >= last then
        return
      end

      self.buffer:move_cursor(start)

      section:close_all_folds(self.buffer.ui)
      section:open_all_folds(self.buffer.ui, 2)
      section:close_all_folds(self.buffer.ui)
      section:open_all_folds(self.buffer.ui, 2)

      self.buffer.ui:update()

      if context then
        local start, _ = context:row_range_abs()
        self.buffer:move_cursor(start)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth4 = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    local context = self.buffer.ui:get_cursor_context()

    if section then
      local start, last = section:row_range_abs()
      if self.buffer:cursor_line() < start or self.buffer:cursor_line() >= last then
        return
      end

      self.buffer:move_cursor(start)
      section:close_all_folds(self.buffer.ui)
      section:open_all_folds(self.buffer.ui, 3)

      self.buffer.ui:update()

      if context then
        local start, _ = context:row_range_abs()
        self.buffer:move_cursor(start)
      end
    end
  end
end

---@param _self StatusBuffer
---@return fun(): nil
M.n_command_history = function(_self)
  return a.void(function()
    require("sven.buffers.command_history"):new():show()
  end)
end

---Puts text into the unnamed register, and into the clipboard when there is one.
---@param text string
function M.yank(text)
  if text == "" then
    vim.cmd("echo ''")
    return
  end

  fn.setreg('"', text)
  if fn.has("clipboard") == 1 then
    pcall(fn.setreg, "+", text)
  end

  api.nvim_echo({ { text } }, false, {})
end

---@param self StatusBuffer
---@return fun(): nil
M.n_yank_selected = function(self)
  return function()
    M.yank(self.buffer.ui:get_yankable_under_cursor() or "")
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_discard = function(self)
  return a.void(function()
    local ui = self.buffer.ui
    local selection = ui:get_selection()
    if not selection.section or not lists_files(selection.section.name) then
      return
    end

    local item = selection.item
    local plan = discard_plan()
    local message

    if is_status_item(item) and item.first == fn.line(".") then -- Discard File
      plan_item(plan, item)
      message = discard_question(item)
    elseif is_status_item(item) then -- Discard Hunk
      local refusal = hunk_refusal(item)
      if refusal then
        notification.warn(refusal)
        return
      end

      local hunk = ui:item_hunks(item, selection.first_line, selection.last_line, false)[1]
      if not hunk then
        notification.info(
          ("There is no hunk here. Property changes can only be discarded with the rest of %s."):format(
            display_name(item)
          )
        )
        return
      end

      table.insert(plan.hunks, { item = item, hunk = hunk.hunk })
      message = ("Discard this hunk of %q?\n  %s"):format(item.name, hunk.hunk.line)
    else -- Discard Section
      local items = vim.tbl_filter(is_status_item, selection.section.items)
      if #items == 0 then
        return
      end

      for _, section_item in ipairs(items) do
        plan_item(plan, section_item)
      end

      if #items == 1 then
        message = discard_question(items[1])
      elseif selection.section.name == "unversioned" then
        message = ("Delete these %d unversioned items from disk?\n%s"):format(#items, list(items))
      elseif selection.section.name == "conflicts" then
        message = ("Discard all local changes to these %d items and drop their conflicts?\n%s"):format(
          #items,
          list(items)
        )
      else
        message = ("Discard all changes to these %d items?\n%s"):format(#items, list(items))
      end
    end

    if input.get_permission(message) then
      discard(self, plan, "n_discard")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_go_to_next_hunk_header = function(self)
  return function()
    local c = self.buffer.ui:get_component_under_cursor(function(c)
      return c.options.tag == "Diff" or c.options.tag == "Hunk" or c.options.tag == "Item"
    end)
    local section = self.buffer.ui:get_current_section()

    if c and section then
      local _, section_last = section:row_range_abs()
      local next_location

      if c.options.tag == "Diff" then
        next_location = fn.line(".") + 1
      elseif c.options.tag == "Item" then
        vim.cmd("normal! zo")
        next_location = fn.line(".") + 1
      elseif c.options.tag == "Hunk" then
        local _, last = c:row_range_abs()
        next_location = last + 1
      end

      if next_location <= section_last then
        self.buffer:move_cursor(next_location)
      end

      vim.cmd("normal! zt")
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_go_to_previous_hunk_header = function(self)
  return function()
    local function previous_hunk_header(self, line)
      local c = self.buffer.ui:get_component_on_line(line, function(c)
        return c.options.tag == "Diff" or c.options.tag == "Hunk" or c.options.tag == "Item"
      end)

      if c then
        local first, _ = c:row_range_abs()
        if fn.line(".") == first then
          first = previous_hunk_header(self, line - 1)
        end

        return first
      end
    end

    local previous_header = previous_hunk_header(self, fn.line("."))
    if previous_header then
      self.buffer:move_cursor(previous_header)
      vim.cmd("normal! zt")
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage = function(self)
  return a.void(function()
    local ui = self.buffer.ui
    local stagable = ui:get_hunk_or_filename_under_cursor()
    local section = ui:get_current_section()
    local selection = ui:get_selection()

    if not section or not is_stageable(section.options.section) then
      return
    end

    if stagable then
      local item = selection.item
      if not is_status_item(item) then
        return
      end

      -- There is no index to put a hunk into: the file is staged, or it is not
      if stagable.hunk then
        notify_whole_files("stage", { item })
      end

      stage(self, { item }, "n_stage")
    elseif selection.section then
      local items = vim.tbl_filter(is_status_item, selection.section.items)
      if #items > 0 then
        stage(self, items, "n_stage")
      end
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage_all = function(self)
  return a.void(function()
    svn.changelist.stage_all()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage_all")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage_unstaged = function(self)
  return a.void(function()
    svn.changelist.stage_changes()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage_unstaged")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_unstage = function(self)
  return a.void(function()
    local ui = self.buffer.ui
    local unstagable = ui:get_hunk_or_filename_under_cursor()
    local selection = ui:get_selection()

    local section = ui:get_current_section()
    if not section or section.options.section ~= "staged" then
      return
    end

    if unstagable then
      local item = selection.item
      if not is_status_item(item) then
        return
      end

      if unstagable.hunk then
        notify_whole_files("unstage", { item })
      end

      svn.changelist.unstage { item.name }
      self:dispatch_refresh({ update_diffs = { "*:" .. item.name } }, "n_unstage")
    else
      svn.changelist.unstage_all()
      self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_unstage")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_unstage_staged = function(self)
  return a.void(function()
    svn.changelist.unstage_all()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_unstage_all")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_goto_file = function(self)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()

    -- Goto FILE
    if is_status_item(item) then
      if not openable(item) then
        return
      end

      local cursor = translate_cursor_location(self, item)
      self:close()
      vim.schedule_wrap(open)("edit", item.absolute_path, cursor)
      return
    end

    -- Goto REVISION
    local commit = self.buffer.ui:get_commit_under_cursor()
    if commit then
      local view = revision_view()
      if view then
        guarded("revision view", function()
          view.new(commit):open()
        end)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_peek_file = function(self)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()

    if is_status_item(item) then
      if openable(item) then
        open("split", item.absolute_path, translate_cursor_location(self, item))
        self.buffer:focus()
      end

      return
    end

    local commit = self.buffer.ui:get_commit_under_cursor()
    if commit then
      peek_revision(self, commit)
    end
  end
end

---@param self StatusBuffer
---@param command string A command that opens a file
---@return fun(): nil
local function open_with(self, command)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()

    if is_status_item(item) and openable(item) then
      open(command, item.absolute_path, translate_cursor_location(self, item))
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_tab_open = function(self)
  return open_with(self, "tabedit")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_split_open = function(self)
  return open_with(self, "split")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_vertical_split_open = function(self)
  return open_with(self, "vsplit")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_blame = function(self)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()
    if not is_status_item(item) then
      notification.info("There is no file under the cursor to blame")
      return
    end

    if item.kind == "dir" then
      notification.info(("%s is a directory: only files can be blamed"):format(display_name(item)))
      return
    end

    if item.status == "unversioned" or (item.status == "added" and not item.copied) then
      notification.info(("%s is %s: it has no history to blame yet"):format(item.name, item.status))
      return
    end

    local blame = optional("sven.buffers.blame_view", "blame view")
    if not blame then
      return
    end

    -- Like going to the file: the blame view shows it in place of the status buffer
    self:close()
    vim.schedule(function()
      guarded("blame view", blame.open, item.absolute_path)
    end)
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_help_popup = function(self)
  return popup(self, "help")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_commit_popup = function(self)
  return popup(self, "commit")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_log_popup = function(self)
  return popup(self, "log")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_diff_popup = function(self)
  return popup(self, "diff")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_update_popup = function(self)
  return popup(self, "update")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_resolve_popup = function(self)
  return popup(self, "resolve")
end

---Opens the repository location of the item under the cursor (or of the working copy) in a
---browser, which only works for repositories that are served over http.
---@param self StatusBuffer
---@return fun(): nil
M.n_open_tree = function(self)
  return a.void(function()
    local info = svn.repo.state.info
    local url = info and info.url
    if not url then
      notification.warn("The URL of the working copy is not known yet")
      return
    end

    local item = self.buffer.ui:get_item_under_cursor()
    if is_status_item(item) and item.status ~= "unversioned" and item.name ~= "." then
      url = url .. "/" .. vim.uri_encode(item.name)
    end

    if not url:match("^https?://") then
      notification.warn(("Only http(s) URLs can be opened in a browser, this one is:\n%s"):format(url))
      return
    end

    notification.info(("Opening %q in your browser."):format(url))
    vim.ui.open(url)
  end)
end

---Asks for an svn command and runs it, with its output in the console.
---@param self StatusBuffer|nil
---@return fun(): nil
M.n_command = function(self)
  local process = require("sven.process")
  local runner = require("sven.runner")

  return a.void(function()
    local root = svn.repo.root
    local line = input.get_user_input(("Run command in %s"):format(root), { prepend = "svn " })
    if not line then
      return
    end

    local args = split_command(line)
    if args[1] == "svn" then
      table.remove(args, 1)
    end

    if #args == 0 then
      return
    end

    local cmd = svn.cli.command(args)
    if fn.executable(cmd[1]) ~= 1 then
      notification.error(
        ("svn executable %q not found. Set `svn_executable` in the sven config."):format(cmd[1])
      )
      return
    end

    local proc = process.new {
      cmd = cmd,
      cwd = root ~= "" and root or nil,
      env = svn.cli.env(),
      -- The console shows what went wrong
      on_error = function()
        return false
      end,
      pty = false,
      suppress_console = false,
      user_command = true,
    }

    -- The console exists once the process has been started, which the runner does next
    vim.schedule(function()
      proc:show_console()
    end)

    -- Whatever the command was, the log may have moved on
    svn.repo:invalidate_recent()

    runner.call(proc, {
      callback = function()
        -- Run from the help popup there is no buffer to speak of, but there may be one to refresh
        local status = self or require("sven.buffers.status").shown()
        if status then
          status:dispatch_refresh(nil, "n_command")
        end
      end,
    })
  end)
end

---The section under the cursor. The empty line below a section counts as part of it.
---@param self StatusBuffer
---@return Component|nil
local function section_at_cursor(self)
  local line = fn.line(".")
  return self.buffer.ui:get_current_section(line)
    or (line > 1 and self.buffer.ui:get_current_section(line - 1) or nil)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_next_section = function(self)
  return function()
    local section = section_at_cursor(self)
    if section then
      -- Past the empty line and the title of the next section, onto its first item
      local position = section.position.row_end + 3
      self.buffer:move_cursor(position)
    else
      local first = self.buffer.ui:first_section().first
      if first then
        self.buffer:move_cursor(first + 1)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_prev_section = function(self)
  return function()
    local section = section_at_cursor(self)
    if section then
      -- Above the title is the empty line, above that the end of the previous section
      local prev_section = self.buffer.ui:get_current_section(section.position.row_start - 2)
      if prev_section then
        self.buffer:move_cursor(prev_section.position.row_start + 1)
        return
      end
    end

    self.buffer:win_exec("norm! gg")
  end
end

return M
