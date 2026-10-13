local svn = require("sven.lib.svn")
local notification = require("sven.lib.notification")

---`svn commit`. Contacts the repository.
---
---The message is handed to svn in a temporary file (`-F`), never on the command line.
---@class SvenCommit
local M = {}

-- More targets than this are passed to svn in a file instead of on the command line
local MAX_ARGV_TARGETS = 100

---@param message string
---@return string path of a temporary file holding the message
local function write_message(message)
  local file = vim.fn.tempname() .. ".svn-commit"
  local fd = assert(io.open(file, "wb"))
  fd:write((message:gsub("\r\n", "\n"):gsub("\r", "\n")))
  fd:close()

  return file
end

---@param result SvenCliResult
---@return number|nil
local function committed_revision(result)
  for _, line in ipairs(result.stdout) do
    local revision = line:match("^Committed revision (%d+)%.")
    if revision then
      return tonumber(revision)
    end
  end
end

---@class SvenCommitOpts: SvenCliOpts
---@field args? string[] Additional arguments for `svn commit`: `--no-unlock`, `--keep-changelists`, `--include-externals`

---With `--keep-changelists` svn leaves the committed files in their changelists. That is what
---the flag is for, except for the staging changelist: a file that stayed in there would count as
---staged again with its next modification.
---@param targets string[]|nil The committed targets. nil when the whole working copy was committed
---@param opts SvenCommitOpts|nil
local function leave_staging_changelist(targets, opts)
  local args = { "changelist", "--remove", "--changelist", svn.changelist.staging() }
  local cli_opts = svn.cli.opts(opts, { hidden = true, ignore_error = true })
  cli_opts.await = true

  if not targets then
    cli_opts.paths = { "." }
    svn.cli.run(vim.list_extend(args, { "--depth", "infinity" }), cli_opts)
    return
  end

  vim.list_extend(args, { "--depth", "empty" })
  for first = 1, #targets, MAX_ARGV_TARGETS do
    cli_opts.paths = vim.list_slice(targets, first, first + MAX_ARGV_TARGETS - 1)
    svn.cli.run(args, cli_opts)
  end
end

---@param message string
---@param targets string[]|nil Explicit targets, committed at depth "empty". nil commits the whole working copy
---@param opts SvenCommitOpts|nil
---@return number|nil revision
---@return string|nil err
local function commit(message, targets, opts)
  local message_file = write_message(message)
  local targets_file

  local args = { "commit", "--encoding", "UTF-8", "-F", message_file }
  local extra = opts and opts.args or {}
  vim.list_extend(args, extra)

  local cli_opts = svn.cli.opts(opts, {})

  if targets then
    -- Every target is named explicitly: nothing below a directory may tag along
    vim.list_extend(args, { "--depth", "empty" })

    if #targets > MAX_ARGV_TARGETS then
      targets_file = vim.fn.tempname() .. ".svn-targets"
      local fd = assert(io.open(targets_file, "wb"))
      fd:write(table.concat(svn.cli.targets(targets), "\n") .. "\n")
      fd:close()

      vim.list_extend(args, { "--targets", targets_file })
    else
      cli_opts.paths = targets
    end
  end

  local result = svn.cli.run(args, cli_opts)

  os.remove(message_file)
  if targets_file then
    os.remove(targets_file)
  end

  if result.code ~= 0 then
    return nil, table.concat(result.stderr, "\n")
  end

  local revision = committed_revision(result)
  if not revision then
    return nil, "Nothing was committed"
  end

  if vim.tbl_contains(extra, "--keep-changelists") then
    leave_staging_changelist(targets, opts)
  end

  svn.repo:invalidate_recent()

  return revision, nil
end

---@param name string
---@return string[] The names of all ancestors of `name`, nearest first, without the root
local function ancestors(name)
  local result = {}
  local dir = vim.fs.dirname(name)
  while dir and dir ~= "." and dir ~= "" and dir ~= "/" do
    table.insert(result, dir)
    dir = vim.fs.dirname(dir)
  end

  return result
end

---Turns a set of items into the list of targets a commit of them needs.
---
---  * Changelists (and therefore `svn commit --changelist`) cannot hold directories. A file below
---    a directory that is itself scheduled for addition can only be committed together with that
---    directory, so every added ancestor is made a target as well.
---  * A file below a directory that is scheduled for deletion cannot be committed on its own at
---    all: svn deletes the directory as a whole. Such a file is only acceptable when the
---    directory itself is among the items.
---@param items SvenStatusItem[] The items to commit
---@param all SvenStatusItem[] Every item of the working copy
---@return string[]|nil targets Sorted, parents before children. nil when the items cannot be committed
---@return string|nil err
function M.targets(items, all)
  local by_name = {}
  for _, item in ipairs(all) do
    by_name[item.name] = item
  end

  local targets = {}
  local seen = {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      table.insert(targets, name)
    end
  end

  local selected = {}
  for _, item in ipairs(items) do
    selected[item.name] = true
  end

  for _, item in ipairs(items) do
    if item.conflicted then
      return nil, ("%s is in conflict. Resolve it first."):format(item.name)
    end

    local skip = false
    for _, name in ipairs(ancestors(item.name)) do
      local ancestor = by_name[name]
      if ancestor and ancestor.kind == "dir" then
        if ancestor.status == "added" or ancestor.status == "replaced" then
          add(name)
        elseif ancestor.status == "deleted" then
          if not selected[name] then
            return nil,
              ("%s is inside %s, which is scheduled for deletion. A directory is deleted as a whole: "):format(
                item.name,
                name
              ) .. "stage everything inside it, or commit the directory itself."
          end

          -- Committed as part of its directory
          skip = true
        end
      end
    end

    if not skip then
      add(item.name)
    end
  end

  table.sort(targets)

  return targets, nil
end

---@param opts SvenCliOpts|nil
---@return SvenStatusBuckets|nil buckets
---@return SvenStatusItem[]|nil items
local function fresh_status(opts)
  local status_opts = svn.cli.opts(opts, { hidden = true })
  -- Looking at the working copy is quick and local. Do it in one go, also inside an async
  -- context, so that nothing can change between looking and committing.
  status_opts.await = true

  return svn.status.buckets(status_opts)
end

---@param err string
---@return nil, string
local function refuse(err)
  notification.error("Cannot commit: " .. err)
  return nil, err
end

---The targets `staged` would commit: the staged files and the directories they depend on.
---@param opts SvenCliOpts|nil
---@return string[]|nil targets Paths relative to the working copy root. nil when the staged files cannot be committed
---@return string|nil err
function M.staged_targets(opts)
  local buckets, items = fresh_status(opts)
  if not buckets or not items then
    return nil, "Unable to read the status of the working copy"
  end

  if #buckets.staged.items == 0 then
    return nil, "Nothing is staged"
  end

  return M.targets(buckets.staged.items, items)
end

---Commits what is staged: the members of the staging changelist, plus the directories that
---have to be committed along with them (see `targets`).
---
---  local revision, err = svn.commit.staged("Fix the frobnicator")
---
---Committed files leave the staging changelist.
---@param message string
---@param opts SvenCommitOpts|nil
---@return number|nil revision The new revision. nil when nothing was committed; the user has been notified why
---@return string|nil err
function M.staged(message, opts)
  local targets, err = M.staged_targets(opts)
  if not targets then
    return refuse(err or "Unknown error")
  end

  return commit(message, targets, opts)
end

---Commits every local change of the working copy, staged or not, whatever changelist it is in.
---Unversioned files are not included.
---@param message string
---@param opts SvenCommitOpts|nil
---@return number|nil revision The new revision. nil when nothing was committed
---@return string|nil err
function M.all(message, opts)
  return commit(message, nil, opts)
end

---Commits the changes of some paths. A directory stands for every change below it.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param message string
---@param opts SvenCommitOpts|nil
---@return number|nil revision The new revision. nil when nothing was committed; the user has been notified why
---@return string|nil err
function M.paths(paths, message, opts)
  if not paths or #paths == 0 then
    return refuse("No paths given")
  end

  local buckets, items = fresh_status(opts)
  if not buckets or not items then
    return refuse("Unable to read the status of the working copy")
  end

  local status_opts = svn.cli.opts(opts, {})
  paths = svn.cli.relative_paths(paths, status_opts.cwd)

  local function selected(name)
    for _, path in ipairs(paths) do
      if path == "." or name == path or vim.startswith(name, path .. "/") then
        return true
      end
    end

    return false
  end

  local to_commit = vim.tbl_filter(function(item)
    return selected(item.name)
      and item.status ~= "unversioned"
      and item.status ~= "ignored"
      and item.status ~= "external"
      and item.status ~= "normal"
  end, items)

  if #to_commit == 0 then
    return refuse("There are no changes in " .. table.concat(paths, ", "))
  end

  local targets, err = M.targets(to_commit, items)
  if not targets then
    return refuse(err or "Unknown error")
  end

  return commit(message, targets, opts)
end

---What a commit is going to send, worked out before the message is written.
---@class SvenCommitPlan
---@field kind string "staged"|"all"|"paths"
---@field paths string[]|nil The paths a "paths" commit was asked for
---@field targets string[]|nil The targets of `svn commit`. nil for "all": the whole working copy
---@field items SvenStatusItem[] Every item the commit sends, sorted by name

---@param status string
---@return boolean whether an item with this status is part of a commit of everything
local function is_committable(status)
  return status == "modified" or status == "added" or status == "deleted" or status == "replaced"
end

---Works out what a commit would send, without committing anything.
---
---  local plan, err = svn.commit.plan("staged")
---  if plan then
---    for _, item in ipairs(plan.items) do print(item.mode, item.name) end
---    local revision = svn.commit.run(plan, "Fix the frobnicator")
---  end
---@param kind string "staged" (the staging changelist), "all" (every local change) or "paths"
---@param paths string[]|nil For "paths": paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|nil
---@return SvenCommitPlan|nil plan nil when there is nothing to commit, or when it cannot be committed
---@return string|nil err
function M.plan(kind, paths, opts)
  local buckets, items = fresh_status(opts)
  if not buckets or not items then
    return nil, "Unable to read the status of the working copy"
  end

  local by_name = {}
  for _, item in ipairs(items) do
    by_name[item.name] = item
  end

  ---@param names string[]
  ---@return SvenStatusItem[]
  local function items_of(names)
    local result = {}
    for _, name in ipairs(names) do
      table.insert(result, by_name[name])
    end

    return result
  end

  if kind == "staged" then
    if #buckets.staged.items == 0 then
      return nil, "Nothing is staged"
    end

    local targets, err = M.targets(buckets.staged.items, items)
    if not targets then
      return nil, err
    end

    return { kind = kind, targets = targets, items = items_of(targets) }, nil
  end

  local selected = function()
    return true
  end

  if kind == "paths" then
    if not paths or #paths == 0 then
      return nil, "No paths given"
    end

    paths = svn.cli.relative_paths(paths, svn.cli.opts(opts, {}).cwd)
    selected = function(name)
      for _, path in ipairs(paths) do
        if path == "." or name == path or vim.startswith(name, path .. "/") then
          return true
        end
      end

      return false
    end
  end

  local to_commit = vim.tbl_filter(function(item)
    return selected(item.name) and (is_committable(item.status) or item.conflicted)
  end, items)

  if #to_commit == 0 then
    if kind == "paths" then
      return nil, "There are no changes in " .. table.concat(paths --[[@as string[] ]], ", ")
    end

    return nil, "No changes to commit"
  end

  -- Checks for conflicts, and works out the directories that have to come along
  local targets, err = M.targets(to_commit, items)
  if not targets then
    return nil, err
  end

  if kind == "paths" then
    return { kind = kind, paths = paths, targets = targets, items = items_of(targets) }, nil
  end

  table.sort(to_commit, function(a, b)
    return a.name < b.name
  end)

  return { kind = "all", targets = nil, items = to_commit }, nil
end

---Commits what a plan describes. The working copy may have changed since the plan was made:
---a "staged" plan commits what is staged now, the others commit their targets as they are now.
---@param plan SvenCommitPlan
---@param message string
---@param opts SvenCommitOpts|nil
---@return number|nil revision The new revision. nil when nothing was committed; the user has been notified why
---@return string|nil err
function M.run(plan, message, opts)
  if plan.kind == "staged" then
    return M.staged(message, opts)
  elseif plan.kind == "paths" then
    return M.paths(plan.paths or {}, message, opts)
  end

  return M.all(message, opts)
end

return M
