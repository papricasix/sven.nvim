local svn = require("sven.lib.svn")
local config = require("sven.config")

---Changelists, and staging in particular.
---
---Subversion has no index. Sven treats membership in one changelist (`config.staging_changelist`,
---"sven-staged" by default) as "staged": `commit.staged` commits exactly its members. Things to
---know about that model:
---
---  * Staging is per file. There is no partial staging of a file.
---  * A file is in at most one changelist. Staging a member of another changelist moves it, and
---    unstaging does not move it back.
---  * Changelists hold files only. Staging a directory stages the changed files below it. Changes
---    to a directory itself (an added empty directory, a property change) cannot be staged; they
---    are committed by `commit.all` or `commit.paths`.
---  * Unversioned paths are scheduled for addition when staged, missing ones for deletion.
---    Unstaging does not undo that scheduling.
---
---All functions here are local operations. They block Neovim while svn runs (`await`), which
---keeps consecutive operations on the working copy from overlapping.
---@class SvenChangelist
local M = {}

---@return string The name of the staging changelist
function M.staging()
  return config.get_staging_changelist()
end

---@param opts table|nil
---@param defaults SvenCliOpts
---@return SvenCliOpts
local function cli_opts(opts, defaults)
  defaults.await = true
  return svn.cli.opts(opts, defaults)
end

---Puts paths into a changelist. Directories are descended into: every versioned file below them
---becomes a member, changed or not.
---@param name string Name of the changelist
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.add(name, paths, opts)
  if #paths == 0 then
    return true
  end

  local result = svn.cli.run({ "changelist", "--depth", "infinity", name }, cli_opts(opts, { paths = paths }))
  return result.code == 0
end

---Removes paths (and everything below them) from their changelist.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|{ changelist: string? }|nil `changelist` limits the removal to members of that changelist
---@return boolean ok
function M.remove(paths, opts)
  if #paths == 0 then
    return true
  end

  local args = { "changelist", "--remove", "--depth", "infinity" }
  if opts and opts.changelist then
    vim.list_extend(args, { "--changelist", opts.changelist })
  end

  local result = svn.cli.run(args, cli_opts(opts, { paths = paths }))
  return result.code == 0
end

---Drops paths that lie below another path of the list
---@param paths string[]
---@return string[]
local function top_level(paths)
  local sorted = vim.deepcopy(paths)
  table.sort(sorted)

  local result = {}
  for _, path in ipairs(sorted) do
    local last = result[#result]
    if not (last and (last == "." or vim.startswith(path, last .. "/"))) then
      table.insert(result, path)
    end
  end

  return result
end

---Stages status items: schedules what svn does not track yet, then makes the files members of
---the staging changelist.
---@param items SvenStatusItem[]
---@param opts SvenCliOpts|nil
---@return boolean ok
local function stage_items(items, opts)
  local to_add = {}
  local to_delete = {}
  local members = {}

  for _, item in ipairs(items) do
    if item.status == "unversioned" then
      table.insert(to_add, item.name)
      table.insert(members, item.name)
    elseif item.status == "missing" then
      table.insert(to_delete, item.name)
      table.insert(members, item.name)
    elseif item.kind ~= "dir" then
      table.insert(members, item.name)
    elseif item.status == "deleted" or item.status == "replaced" then
      -- svn status does not report what is below such a directory. All of it is a change.
      -- (The files below a directory scheduled for addition are reported one by one.)
      table.insert(members, item.name)
    end
  end

  if #to_add == 0 and #to_delete == 0 and #members == 0 then
    if #items > 0 then
      require("sven.lib.notification").warn(
        "Nothing to stage: a change to a directory itself (an added empty directory, a property change) "
          .. "cannot be a member of a changelist. Commit it with the files inside it, or commit all."
      )
    end

    return true
  end

  if #to_add > 0 then
    local result = svn.cli.run(
      { "add", "--parents", "--depth", "infinity" },
      cli_opts(opts, { paths = top_level(to_add) })
    )
    if result.code ~= 0 then
      return false
    end
  end

  if #to_delete > 0 then
    local result = svn.cli.run({ "delete" }, cli_opts(opts, { paths = top_level(to_delete) }))
    if result.code ~= 0 then
      return false
    end
  end

  return M.add(M.staging(), top_level(members), opts)
end

---Stages paths.
---
---  * Unversioned files and directories are added first (`svn add --parents`, recursively).
---  * Missing files and directories are scheduled for deletion first (`svn delete`).
---  * For a directory, the changed files below it are staged. Unchanged files are left alone.
---
---Paths without changes are ignored.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.stage(paths, opts)
  if not paths or #paths == 0 then
    return true
  end

  local fetch_opts = cli_opts(opts, { hidden = true }) --[[@as SvenStatusFetchOpts]]
  paths = svn.cli.relative_paths(paths, fetch_opts.cwd)
  fetch_opts.paths = paths

  local items = svn.status.fetch(fetch_opts)
  if not items then
    return false
  end

  -- svn status has nothing to say about paths inside an unversioned directory. They can still
  -- be staged, which adds their parents as well.
  local reported = {}
  for _, item in ipairs(items) do
    reported[item.name] = true
    reported[item.absolute_path] = true
  end

  local silent = {}
  for _, path in ipairs(paths) do
    if not reported[path] and vim.uv.fs_lstat(vim.fs.joinpath(fetch_opts.cwd or svn.repo.root, path)) then
      table.insert(silent, path)
    end
  end

  if #silent > 0 then
    local known = {}
    local info_opts = cli_opts(opts, { hidden = true, ignore_error = true }) --[[@as SvenInfoOpts]]
    for _, info in ipairs(svn.info.list(silent, info_opts)) do
      known[info.path] = true
    end

    for _, path in ipairs(silent) do
      if not known[path] then
        table.insert(items, { name = path, status = "unversioned", kind = "file" })
      end
    end
  end

  local conflicted = {}
  for _, item in ipairs(items) do
    if item.conflicted then
      conflicted[item.name] = true
    end
  end

  -- Leave out what has no changes, and the files svn put next to conflicted files
  items = vim.tbl_filter(function(item)
    if item.status == "unversioned" then
      return not svn.status.is_conflict_artifact(item.name, conflicted)
    end

    return item.status ~= "normal" and item.status ~= "external" and item.status ~= "ignored"
  end, items)

  if #items == 0 then
    return true
  end

  return stage_items(items, opts)
end

---Unstages paths (and everything below them). Files stay scheduled for addition or deletion.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.unstage(paths, opts)
  if not paths or #paths == 0 then
    return true
  end

  return M.remove(paths, vim.tbl_extend("force", opts or {}, { changelist = M.staging() }))
end

---@param opts SvenCliOpts|nil
---@param sections string[]
---@return boolean ok
local function stage_sections(opts, sections)
  local buckets = svn.status.buckets(cli_opts(opts, { hidden = true }) --[[@as SvenStatusFetchOpts]])
  if not buckets then
    return false
  end

  local items = {}
  for _, section in ipairs(sections) do
    vim.list_extend(items, buckets[section].items)
  end

  if #items == 0 then
    return true
  end

  return stage_items(items, opts)
end

---Stages every change that is not staged yet: versioned changes that are in no changelist and
---unversioned paths. Members of other changelists and conflicted items are left alone.
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.stage_all(opts)
  return stage_sections(opts, { "changes", "unversioned" })
end

---Stages the versioned changes that are in no changelist. Unversioned paths, members of other
---changelists and conflicted items are left alone.
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.stage_changes(opts)
  return stage_sections(opts, { "changes" })
end

---Unstages everything.
---@param opts SvenCliOpts|nil
---@return boolean ok
function M.unstage_all(opts)
  return M.unstage({ "." }, opts)
end

return M
