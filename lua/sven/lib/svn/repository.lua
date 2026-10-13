local a = require("sven.lib.async")
local logger = require("sven.logger")
local svn = require("sven.lib.svn")
local config = require("sven.config")
local event = require("sven.lib.event")
local ItemFilter = require("sven.lib.item_filter")

-- Modules that contribute to the state. Each registers one or more `update_*` functions,
-- which are run concurrently on every refresh.
local modules = {
  "status",
}

---@class SvenRepoRecent
---@field items SvenLogEntry[] The newest log entries of the working copy URL, newest first
---@field loading boolean Whether a fetch is in flight

---The state of a working copy. Replaced as a whole on every refresh: never keep a reference to
---an old state, always read `repo.state`.
---@class SvenRepoState
---@field root string Absolute path of the working copy root
---@field info SvenInfoEntry|nil `svn info` of the working copy root: URL, revision, last change. nil until the first refresh finished
---@field conflicts SvenStatusBucket Conflicted items (text, property and tree conflicts)
---@field unversioned SvenStatusBucket Unversioned files and directories
---@field changes SvenStatusBucket Versioned changes that are in no changelist ("unstaged")
---@field staged SvenStatusBucket Members of the staging changelist, plus the directories they depend on
---@field changelists SvenChangelistBucket[] Every other changelist, sorted by name: `{ name, items }`
---@field recent SvenRepoRecent Recent log entries. Fetched in the background, see `SvenRepo:refresh_recent`

---@param root string
---@param recent SvenRepoRecent
---@return SvenRepoState
local function empty_state(root, recent)
  return {
    root = root,
    info = nil,
    conflicts = { items = {} },
    unversioned = { items = {} },
    changes = { items = {} },
    staged = { items = {} },
    changelists = {},
    recent = recent,
  }
end

---One instance per working copy.
---@class SvenRepo
---@field root string Absolute path of the working copy root (symlinks resolved). "" when the directory is not inside a working copy
---@field state SvenRepoState
---@field lib table<string, fun(state: SvenRepoState, filter: ItemFilter, repo: SvenRepo)> The `update_*` functions run on refresh
---@field refresh_callbacks table<string, function> Callbacks waiting for the running refresh, by source
---@field kind_cache table<string, string> See `sven.lib.svn.status.resolve_kinds`
---@field _refresh_task SvenTask|nil Active refresh task (cancellable)
local Repo = {}
Repo.__index = Repo

---@type table<string, SvenRepo> by working copy root
local instances = {}

---@type table<string, string> directory -> working copy root ("" when it is not inside one)
local roots = {}

local lastDir = vim.uv.cwd()

---@param dir string
---@param redetect boolean|nil Look again when the directory was not inside a working copy before
---@return string
local function root_of(dir, redetect)
  if roots[dir] == nil or (roots[dir] == "" and redetect) then
    roots[dir] = svn.cli.wc_root(dir)
  end

  return roots[dir]
end

---The repository of the working copy that contains `dir`, without making it the current one.
---@param dir string
---@param redetect boolean|nil Look again when the directory was not inside a working copy before
---@return SvenRepo
function Repo.find(dir, redetect)
  dir = vim.fs.normalize(dir)

  local root = root_of(dir, redetect)
  local key = root ~= "" and root or ("\0" .. dir)

  if not instances[key] then
    logger.debug("[REPO]: Registered Repository for: " .. (root ~= "" and root or dir))
    instances[key] = Repo.new(root)
    instances[key]:dispatch_refresh()
  end

  return instances[key]
end

---@return SvenRepo[] Every repository that was looked up so far
function Repo.all()
  return vim.tbl_values(instances)
end

---Whether background work is going on: a refresh, or a fetch of the recent log entries
---@return boolean
function Repo:busy()
  return self.recent.loading or (self._refresh_task ~= nil and not self._refresh_task:done())
end

---The current repository: `require("sven.lib.svn").repo` is `Repo.instance()`.
---
---Like in Neogit there is one current repository at a time: the one of the directory that was
---passed here last (initially Neovim's working directory). Every function of `sven.lib.svn`
---operates on it. `require("sven").open()` and the status buffer make their working copy current.
---@param dir? string Directory inside a working copy. Makes that working copy the current one
---@return SvenRepo
function Repo.instance(dir)
  local redetect = dir ~= nil
  if dir and dir ~= lastDir then
    lastDir = dir
  end

  assert(lastDir, "No last dir")
  return Repo.find(lastDir, redetect)
end

-- Use Repo.instance when calling directly to ensure it's registered
---@param root string Working copy root, "" for a directory that is not inside a working copy
---@return SvenRepo
function Repo.new(root)
  logger.debug("[REPO]: Initializing Repository")

  local recent = { items = {}, loading = false }

  local instance = {
    lib = {},
    root = root,
    recent = recent,
    state = empty_state(root, recent),
    refresh_callbacks = {},
    kind_cache = {},
    _refresh_task = nil,
    _recent_key = nil,
    _recent_generation = 0,
    _recent_failed_at = nil,
  }

  setmetatable(instance, Repo)

  for _, m in ipairs(modules) do
    require("sven.lib.svn." .. m).register(instance.lib)
  end

  instance.lib.update_info = function(state, _, repo)
    local info = svn.info.get(".", { cwd = repo.root, hidden = true, ignore_error = true })
    if info then
      state.info = info
    end
  end

  return instance
end

---Forgets everything known about the working copy. The next refresh starts from scratch.
function Repo:reset()
  self.recent.items = {}
  self.recent.loading = false
  self.state = empty_state(self.root, self.recent)
  self.kind_cache = {}
  self._recent_key = nil
  self._recent_failed_at = nil
end

---@param path string Absolute path, or a path relative to Neovim's working directory
---@return string|nil relative Path relative to the working copy root ("." for the root itself), nil when it is outside
function Repo:relpath(path)
  if self.root == "" or not path or path == "" then
    return nil
  end

  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))

  -- Resolve symlinks of the part that exists, the working copy root is a real path
  local real = vim.uv.fs_realpath(absolute)
  if not real then
    local parent = vim.uv.fs_realpath(vim.fs.dirname(absolute))
    real = parent and vim.fs.joinpath(parent, vim.fs.basename(absolute)) or absolute
  end
  real = vim.fs.normalize(real)

  if real == self.root then
    return "."
  end

  if vim.startswith(real, self.root .. "/") then
    return real:sub(#self.root + 2)
  end

  return nil
end

---@param ... string Path components below the working copy root
---@return string Absolute path
function Repo:path(...)
  return vim.fs.joinpath(self.root, ...)
end

function Repo:tasks(filter, state)
  local tasks = {}
  for name, fn in pairs(self.lib) do
    table.insert(tasks, function()
      local start = vim.uv.now()
      fn(state, filter, self)
      logger.debug(("[REPO]: Refreshed %s in %d ms"):format(name, vim.uv.now() - start))
    end)
  end

  return tasks
end

function Repo:register_callback(source, fn)
  logger.debug("[REPO] Callback registered from " .. source)
  self.refresh_callbacks[source] = fn
end

function Repo:run_callbacks(id)
  local callbacks = self.refresh_callbacks
  self.refresh_callbacks = {}

  for source, fn in pairs(callbacks) do
    logger.debug("[REPO]: (" .. id .. ") Running callback for " .. source)
    fn()
  end
end

local DEFAULT_FILTER = ItemFilter.create { "*:*" }

local function timestamp()
  vim.uv.update_time()
  return vim.uv.now()
end

---@class SvenRefreshOpts
---@field source? string Who asks. A later refresh from the same source replaces the callback of an earlier one
---@field callback? fun() Called once, when the state is up to date. Recent log entries may still be loading
---@field partial? { update_diffs: string[]? } `update_diffs` lists the items whose cached diff is stale, as "<section>:<path>" with "*" as wildcard, e.g. `{ "*:src/main.c" }`. Without it every cached diff is dropped

---Refreshes `self.state` from svn: status and info (local, quick), then the recent log entries
---(in the background, see `refresh_recent`).
---
---Never blocks. A refresh that is still running is cancelled and its callbacks are carried over,
---so that any number of refresh requests results in one final state and every callback is called
---exactly once, after the newest refresh.
---@param opts SvenRefreshOpts|nil
function Repo:refresh(opts)
  opts = opts or {}

  if self.root == "" then
    logger.debug("[REPO] No working copy found - skipping refresh")
    if opts.callback then
      opts.callback()
    end
    return
  end

  local start = timestamp()

  if opts.callback then
    self:register_callback(opts.source or "unknown", opts.callback)
  end

  -- Cancel any in-flight refresh.  This propagates to per-module sub-tasks
  -- which in turn kill the underlying svn subprocesses (see Process:stop).
  local cancelled_filter = nil
  if self._refresh_task and not self._refresh_task:done() then
    logger.debug("[REPO] (" .. start .. ") Cancelling in-flight refresh")
    self._refresh_task:cancel()
    cancelled_filter = self._refresh_filter
  end

  local filter
  if opts.partial and opts.partial.update_diffs then
    filter = ItemFilter.create(opts.partial.update_diffs)
  else
    filter = DEFAULT_FILTER
  end

  -- The diffs the cancelled refresh was going to drop are still stale: a partial refresh that
  -- overtakes a full one must not keep them.
  if cancelled_filter then
    filter = ItemFilter.new(vim.list_extend(vim.list_extend({}, cancelled_filter), filter))
  end
  self._refresh_filter = filter

  -- The modules fill a copy, which replaces the state once all of them are done
  local state = vim.tbl_extend("force", {}, self.state)
  state.recent = self.recent

  local task
  task = a.util.run_all(self:tasks(filter, state), function()
    if task and task:cancelled() then
      logger.debug("[REPO]: (" .. start .. ") Refresh cancelled before completion")
      return
    end

    logger.debug("[REPO]: (" .. start .. ") Refreshes complete in " .. timestamp() - start .. " ms")
    self.state = state
    self:run_callbacks(start)
    self:refresh_recent()
  end)

  self._refresh_task = task
end

---Like `refresh`, and returns the task: `repo:dispatch_refresh():wait(5000)` blocks until the
---state is up to date.
---@param opts SvenRefreshOpts|nil
---@return SvenTask|nil task nil when there is no working copy
function Repo:dispatch_refresh(opts)
  self:refresh(opts)
  return self._refresh_task
end

-- After a failed fetch (offline, server down) the log is not asked for again for this long
local RECENT_RETRY_MS = 60 * 1000

---Marks the cached recent log entries as stale. Called after a commit and after an update.
function Repo:invalidate_recent()
  self._recent_generation = self._recent_generation + 1
  self._recent_failed_at = nil
end

---Fetches the recent log entries (`config.status.recent_commit_count` of them) into
---`state.recent.items`, unless they are cached.
---
---`svn log` talks to the server, so this never blocks a refresh: it runs in the background and
---fires the `User SvenRecentLoaded` autocmd (data: `{ root = <working copy root> }`) once the
---entries changed, for views to redraw. The result is cached per base revision of the working
---copy and invalidated by commits and updates made through sven.
---@param opts { force: boolean? }|nil `force` ignores the cache
function Repo:refresh_recent(opts)
  opts = opts or {}

  local count = config.values.status.recent_commit_count
  if self.root == "" or not count or count <= 0 then
    self.recent.items = {}
    return
  end

  local info = self.state.info
  local key = ("%s:%d:%d"):format(info and info.revision or "?", self._recent_generation, count)

  if not opts.force then
    if self._recent_key == key or self.recent.loading then
      return
    end

    if self._recent_failed_at and timestamp() - self._recent_failed_at < RECENT_RETRY_MS then
      return
    end
  end

  self.recent.loading = true
  local generation = self._recent_generation

  a.run(function()
    local entries = svn.log.list {
      limit = count,
      cwd = self.root,
      hidden = true,
      ignore_error = true,
    }

    self.recent.loading = false

    if not entries then
      logger.debug("[REPO]: Unable to fetch the recent log entries")
      self._recent_failed_at = timestamp()
      return
    end

    self._recent_failed_at = nil
    if generation == self._recent_generation then
      self._recent_key = key
    end

    self.recent.items = entries
    event.send("RecentLoaded", { root = self.root })
  end)
end

return Repo
