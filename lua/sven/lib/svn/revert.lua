local svn = require("sven.lib.svn")
local config = require("sven.config")
local notification = require("sven.lib.notification")
local logger = require("sven.logger")

---Discarding local changes. Everything here is a local operation.
---
---`hunk` and `unversioned` block Neovim while they work, they are quick. `files` follows the
---general convention instead (it suspends inside an async context): after writing working files
---`svn revert` waits for the clock to move on, for up to a second, so that later modifications
---of the files cannot go unnoticed. Blocking would freeze the editor for that long.
---@class SvenRevert
local M = {}

---@param opts table|nil
---@param defaults SvenCliOpts
---@return SvenCliOpts
local function cli_opts(opts, defaults)
  defaults.await = true
  return svn.cli.opts(opts, defaults)
end

---Reverts paths to their pristine state (`svn revert`), recursively for directories.
---
---Scheduled additions become unversioned again (the files stay on disk), scheduled deletions
---and missing files are restored, conflicts are dropped. Reverted files also leave the staging
---changelist; membership in other changelists is kept.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|{ depth: string? }|nil `depth` defaults to "infinity". "empty" reverts only the changes of the paths themselves: the way to discard a property change of a directory without reverting everything below it
---@return boolean ok
function M.files(paths, opts)
  if not paths or #paths == 0 then
    return true
  end

  local depth = opts and opts.depth or "infinity"

  -- An unmodified file that stays in the staging changelist would be staged again, unnoticed,
  -- by its next modification. This comes first: paths that are scheduled for addition are
  -- unversioned after the revert, and svn refuses those.
  svn.cli.run(
    { "changelist", "--remove", "--changelist", config.get_staging_changelist(), "--depth", depth },
    svn.cli.opts(opts, { paths = paths, hidden = true, ignore_error = true })
  )

  local result = svn.cli.run({ "revert", "--depth", depth }, svn.cli.opts(opts, { paths = paths }))

  return result.code == 0
end

---Applies a patch to the working copy with `svn patch`.
---@param patch string A unified diff with paths relative to the working copy root
---@param opts SvenCliOpts|{ reverse: boolean? }|nil `reverse` applies the patch backwards
---@return boolean ok Whether every hunk was applied
---@return string|nil err Why not
---@return table<string, string> actions What svn did, by path: "U" updated, "G" merged, "A" added, "D" scheduled for deletion, "C" rejected
function M.apply_patch(patch, opts)
  opts = opts or {}

  local file = vim.fn.tempname() .. ".patch"
  local fd = assert(io.open(file, "wb"))
  fd:write(patch)
  fd:close()

  local args = { "patch" }
  if opts.reverse then
    table.insert(args, "--reverse-diff")
  end
  table.insert(args, file)

  local run_opts = cli_opts(opts, {})
  local result = svn.cli.run(args, run_opts)
  os.remove(file)

  local actions = {}

  if result.code ~= 0 then
    return false, table.concat(result.stderr, "\n"), actions
  end

  -- svn patch exits successfully even when nothing could be applied. Its output tells:
  --   U         a.txt
  --   C         a.txt
  --   >         rejected hunk @@ -1,4 +1,4 @@
  --   G         a.txt
  --   >         hunk @@ -1,4 +1,4 @@ already applied
  local rejected = false
  local already_applied = false
  local applied = false

  local root = run_opts.cwd or svn.repo.root
  for _, line in ipairs(result.stdout) do
    local status, path = line:match("^([ADUCG])%s+(.+)$")
    if status then
      actions[path] = status
    end

    if status == "C" then
      rejected = true

      -- Do not leave the reject file behind as an unversioned file
      local reject = vim.fs.joinpath(root, path .. ".svnpatch.rej")
      if vim.uv.fs_stat(reject) then
        os.remove(reject)
      end
    elseif status then
      applied = true
    elseif line:match("^>%s+rejected hunk") then
      rejected = true
    elseif line:match("^>%s+hunk .* already applied") then
      already_applied = true
    end
  end

  if rejected then
    return false, "The change does not apply to the file anymore", actions
  elseif already_applied then
    return false, "The change is not in the file anymore", actions
  elseif not applied then
    return false, "svn patch did not change anything", actions
  end

  return true, nil, actions
end

---Removes a single hunk (or some of its lines) from the working file, by building a patch for it
---and applying that in reverse.
---
---Works for modified and conflicted files. Whole-file changes (added, deleted, unversioned
---files) and property changes are discarded with `files` instead.
---  svn.revert.hunk(item, item.diff.hunks[1])                 -- the whole hunk
---  svn.revert.hunk(item, hunk, { from = 2, to = 3 })         -- its second and third line
---
---For a visual selection, `Ui:item_hunks(item, first, last, true)` yields hunks whose `from` and
---`to` are exactly these offsets: `svn.revert.hunk(item, h, { from = h.from, to = h.to })`.
---@param item SvenStatusItem The item the hunk belongs to
---@param hunk Hunk A hunk of `item.diff`
---@param opts SvenCliOpts|{ from: number?, to: number? }|nil `from`/`to` limit the revert to these lines of the hunk (1-based offsets into `hunk.lines`). Without them the whole hunk is reverted
---@return boolean ok
---@return string|nil err Why not. The user has been notified already
function M.hunk(item, hunk, opts)
  opts = opts or {}

  local function fail(message)
    notification.warn(("Unable to discard the hunk of %s: %s"):format(item.name, message))
    return false, message
  end

  if item.kind == "dir" then
    return fail("it is a directory")
  end

  if item.status ~= "modified" and item.status ~= "conflicted" then
    return fail(("the file is %s. Discard the whole file instead"):format(item.status))
  end

  local patch = svn.diff.generate_patch(
    setmetatable({ file = item.name }, { __index = hunk }),
    { from = opts.from, to = opts.to, reverse = true }
  )
  logger.debug("[REVERT] Reverse applying:\n" .. patch)

  local ok, err, actions =
    M.apply_patch(patch, vim.tbl_extend("force", opts, { reverse = true, ignore_error = true }))
  if not ok then
    return fail(err or "svn patch failed")
  end

  -- svn patch schedules a file for deletion when a patch empties it. That happens when the hunk
  -- was everything the file contained, i.e. the pristine file is empty: revert to that instead.
  if actions[item.name] == "D" then
    svn.cli.run({ "revert" }, cli_opts(opts, { paths = { item.name } }))
  end

  return true, nil
end

---Deletes unversioned (or ignored) files and directories from disk.
---
---Paths that svn tracks are refused, so this can never destroy versioned data. Directories are
---removed with everything in them.
---@param paths string[] Paths relative to the working copy root, or absolute paths
---@param opts SvenCliOpts|nil
---@return boolean ok Whether all paths were deleted
---@return string[] failed The paths that were not deleted
function M.unversioned(paths, opts)
  if not paths or #paths == 0 then
    return true, {}
  end

  local fetch_opts = cli_opts(opts, { hidden = true }) --[[@as SvenStatusFetchOpts]]
  local root = fetch_opts.cwd or svn.repo.root
  paths = svn.cli.relative_paths(paths, fetch_opts.cwd)

  fetch_opts.paths = paths
  fetch_opts.depth = "empty"
  fetch_opts.no_ignore = true

  local unversioned = {}
  for _, item in ipairs(svn.status.fetch(fetch_opts) or {}) do
    if item.status == "unversioned" or item.status == "ignored" then
      unversioned[item.name] = true
    end
  end

  local failed = {}
  for _, path in ipairs(paths) do
    local absolute = vim.fs.normalize(vim.fs.joinpath(root, path))
    local inside = vim.startswith(absolute, root .. "/")

    if not unversioned[path] or not inside then
      table.insert(failed, path)
    elseif vim.fn.delete(absolute, "rf") ~= 0 then
      table.insert(failed, path)
    end
  end

  if #failed > 0 then
    notification.warn(
      "Not deleted, because not unversioned or not removable:\n" .. table.concat(failed, "\n")
    )
  end

  return #failed == 0, failed
end

return M
