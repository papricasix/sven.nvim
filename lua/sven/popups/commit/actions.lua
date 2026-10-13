local M = {}

local svn = require("sven.lib.svn")
local config = require("sven.config")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local event = require("sven.lib.event")
local a = require("sven.lib.async")
local Env = require("sven.popups.diff.env")

---Messages of commits that failed, by working copy root. Offered again by the next commit.
---@type table<string, string>
local kept_messages = {}

---@param root string|nil Defaults to the current working copy
---@return string|nil message The message of the last commit that failed in a working copy
function M.kept_message(root)
  return kept_messages[root or svn.repo.root]
end

---The files the "Commit file" action commits
---@param env SvenPopupContext
---@return string[] Paths relative to the working copy root
function M.files(env)
  if #env.paths > 0 then
    return env.paths
  end

  return env.file and { env.file } or {}
end

---The lines that tell what a commit is going to send, for the comment block of the editor:
---
---  Changes to be committed:
---    M src/main.c
---    A src/new.c
---
---The letters are the ones `svn status` prints. When properties are involved there are two
---columns, as in `svn status`: text first, properties second.
---@param plan SvenCommitPlan
---@return string[]
function M.comments(plan)
  local with_props = false
  for _, item in ipairs(plan.items) do
    if item.prop_mode and item.prop_mode ~= " " then
      with_props = true
      break
    end
  end

  local lines = { "Changes to be committed:" }
  for _, item in ipairs(plan.items) do
    local mode = item.mode
    if with_props then
      local text_unchanged = item.text_status == "normal" or item.text_status == "none"
      mode = (text_unchanged and " " or item.mode) .. (item.prop_mode or " ")
    end

    table.insert(lines, ("  %s %s"):format(mode, item.name))
  end

  return lines
end

---@param plan SvenCommitPlan
---@return string
local function diff_header(plan)
  if plan.kind == "staged" then
    return "Staged changes"
  elseif plan.kind == "paths" then
    local paths = plan.paths or {}
    return #paths == 1 and ("Changes in %s"):format(paths[1]) or ("Changes in %d paths"):format(#paths)
  end

  return "All changes"
end

---The diff of what a commit is going to send
---@param plan SvenCommitPlan
---@return SvenDiffResult
local function diff_of(plan)
  if plan.kind == "all" then
    return svn.diff.working()
  elseif plan.kind == "paths" then
    return svn.diff.working(plan.paths)
  end

  local result = svn.diff.staged()

  -- A staged file can be left out of the commit: one that is in conflict is
  local targets = {}
  for _, item in ipairs(plan.items) do
    targets[item.name] = item
  end

  local function is_sent(file)
    if targets[file] then
      return true
    end

    -- A deleted directory stands for everything below it
    for dir in vim.fs.parents(file) do
      if targets[dir] and targets[dir].status == "deleted" then
        return true
      end
    end

    return false
  end

  result.diffs = vim.tbl_filter(function(diff)
    return is_sent(diff.file)
  end, result.diffs)
  result.stats = nil

  return result
end

---Asks for a message and commits.
---@param popup PopupData
---@param plan SvenCommitPlan
local function do_commit(popup, plan)
  local root = svn.repo.root
  local args = popup:get_arguments()

  local diff_view = nil
  if config.values.commit_editor.show_staged_diff then
    local result = diff_of(plan)
    if #result.diffs > 0 then
      diff_view = function()
        return require("sven.buffers.diff")
          .new({ header = diff_header(plan), diffs = result.diffs, stats = result.stats, root = root })
          :open()
      end
    end
  end

  a.util.scheduler()

  local message = require("sven.buffers.editor").edit {
    message = kept_messages[root],
    comments = M.comments(plan),
    diff_view = diff_view,
  }

  if not message then
    return
  end

  local revision = svn.commit.run(plan, message, { args = args, cwd = root })
  a.util.scheduler()

  if revision then
    kept_messages[root] = nil
    notification.info(("Committed revision %d"):format(revision), { dismiss = true })
    event.send("CommitComplete", { revision = revision, root = root })
  else
    -- svn's complaint has been shown already
    kept_messages[root] = message
    notification.warn("Nothing was committed. Your message is kept: the next commit starts with it.")
  end
end

---@param err string|nil
local function refuse(err)
  if err == "No changes to commit" or err == "Nothing is staged" then
    notification.warn("No changes to commit.")
  else
    notification.error("Cannot commit: " .. (err or "unknown error"))
  end
end

---Commits what is staged. Offers to commit everything when nothing is.
---@param popup PopupData
function M.commit(popup)
  local plan, err = svn.commit.plan("staged")

  if not plan and err == "Nothing is staged" then
    local all, all_err = svn.commit.plan("all")
    if not all then
      return refuse(all_err)
    end

    a.util.scheduler()
    if not input.get_permission("Nothing staged. Commit all changes?") then
      return
    end

    plan = all
  end

  if not plan then
    return refuse(err)
  end

  do_commit(popup, plan)
end

---Commits every local change, staged or not
---@param popup PopupData
function M.commit_all(popup)
  local plan, err = svn.commit.plan("all")
  if not plan then
    return refuse(err)
  end

  do_commit(popup, plan)
end

---Commits the files the popup was opened on (or the file of the buffer it was opened from),
---whether they are staged or not
---@param popup PopupData
function M.commit_files(popup)
  local files = M.files(Env.of(popup))
  if #files == 0 then
    notification.warn("No file to commit.")
    return
  end

  local plan, err = svn.commit.plan("paths", files)
  if not plan then
    return refuse(err)
  end

  do_commit(popup, plan)
end

return M
