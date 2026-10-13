local svn = require("sven.lib.svn")
local config = require("sven.config")
local logger = require("sven.logger")

---`svn status`, parsed into items and sorted into the buckets of `repo.state`.
---@class SvenStatus
local M = {}

---@class SvenStatusItem
---@field name string Path relative to the working copy root, with forward slashes. "." is the root itself
---@field absolute_path string
---@field escaped_path string Same as `name`. NOT shell escaped: it exists so that UI code ported from Neogit, which passes `item.escaped_path` to the backend, works for every file name
---@field status string What happened to the item: "modified"|"added"|"deleted"|"replaced"|"missing"|"unversioned"|"conflicted"|"obstructed"|"incomplete"|"external"|"ignored"|"normal". A property-only modification is "modified", a text or property conflict is "conflicted"
---@field mode string The single letter svn prints for `status`: M A D R ! ? C ~ X I (" " for normal). Key into `config.status.mode_text`
---@field text_status string The raw `item` attribute of svn: like `status`, but "normal" for items whose text is unchanged
---@field props string State of the properties: "none"|"normal"|"modified"|"conflicted"
---@field prop_mode string The letter svn prints in its second column: " ", "M" or "C"
---@field kind string "file"|"dir". Symlinks are files
---@field changelist string|nil Name of the changelist the item is a member of. Directories are never members
---@field copied boolean Scheduled for addition with history (svn copy/move)
---@field switched boolean
---@field locked boolean The working copy administrative area of the item is locked (interrupted operation)
---@field conflicted boolean Any kind of conflict: text, property or tree
---@field text_conflicted boolean
---@field prop_conflicted boolean
---@field tree_conflicted boolean
---@field revision number|nil Base revision. nil for unversioned and newly added items
---@field commit { revision: number|nil, author: string|nil, date: string|nil }|nil Last commit that changed the item
---@field moved_from string|nil Path the item was moved here from
---@field moved_to string|nil Path the item was moved to
---@field section string The bucket the item is in: "conflicts"|"unversioned"|"changes"|"staged"|"changelist:<name>"
---@field implied boolean|nil A directory that is listed as staged because staged files inside it depend on it (see `bucket`)
---@field diff Diff Loaded lazily on first access, see `sven.lib.svn.diff`
---@field first number First line of the item in the buffer (set by the UI)
---@field last number Last line of the item in the buffer (set by the UI)
---@field folded boolean|nil (set by the UI)

---The name the UI core, which comes from Neogit, knows status items by
---@alias StatusItem SvenStatusItem

---@class SvenStatusBucket
---@field items SvenStatusItem[]

---@class SvenChangelistBucket
---@field name string
---@field items SvenStatusItem[]

---@class SvenStatusBuckets
---@field conflicts SvenStatusBucket Everything conflicted, whatever changelist it is in
---@field unversioned SvenStatusBucket Unversioned files and directories. An unversioned directory is one item
---@field changes SvenStatusBucket Versioned changes that are in no changelist
---@field staged SvenStatusBucket Members of the staging changelist, plus the directories a commit of them has to include
---@field changelists SvenChangelistBucket[] Every other changelist, sorted by name

local MODES = {
  modified = "M",
  added = "A",
  deleted = "D",
  replaced = "R",
  conflicted = "C",
  missing = "!",
  incomplete = "!",
  unversioned = "?",
  obstructed = "~",
  external = "X",
  ignored = "I",
  merged = "G",
  normal = " ",
  none = " ",
}

local PROP_MODES = {
  modified = "M",
  conflicted = "C",
}

---@param entry SvenXmlNode
---@param changelist string|nil
---@param root string
---@return SvenStatusItem|nil
local function parse_entry(entry, changelist, root)
  local wc = entry:find("wc-status")
  local name = entry.attrs.path
  if not wc or not name then
    return nil
  end

  name = name:gsub("\\", "/")

  local text_status = wc.attrs.item or "none"
  local props = wc.attrs.props or "none"
  local text_conflicted = text_status == "conflicted"
  local prop_conflicted = props == "conflicted"
  local tree_conflicted = wc.attrs["tree-conflicted"] == "true"

  local status = text_status
  if text_conflicted or prop_conflicted then
    status = "conflicted"
  elseif status == "normal" or status == "none" then
    if props == "modified" then
      status = "modified"
    elseif tree_conflicted then
      status = "conflicted"
    end
  end

  local commit = wc:find("commit")
  local revision = tonumber(wc.attrs.revision)
  if revision and revision < 0 then
    revision = nil
  end

  return {
    name = name,
    absolute_path = name == "." and root or vim.fs.joinpath(root, name),
    escaped_path = name,
    status = status,
    mode = MODES[status] or " ",
    text_status = text_status,
    props = props,
    prop_mode = PROP_MODES[props] or " ",
    changelist = changelist,
    copied = wc.attrs.copied == "true",
    switched = wc.attrs.switched == "true",
    locked = wc.attrs["wc-locked"] == "true",
    conflicted = text_conflicted or prop_conflicted or tree_conflicted,
    text_conflicted = text_conflicted,
    prop_conflicted = prop_conflicted,
    tree_conflicted = tree_conflicted,
    revision = revision,
    commit = commit and {
      revision = tonumber(commit.attrs.revision),
      author = commit:text_of("author"),
      date = commit:text_of("date"),
    } or nil,
    moved_from = wc.attrs["moved-from"],
    moved_to = wc.attrs["moved-to"],
  }
end

---Parses the output of `svn status --xml`. Items come back in the order svn printed them; their
---`kind` is not known yet (see `resolve_kinds`) and they are not in a bucket (see `bucket`).
---@param lines string[]|string
---@param root string Absolute path of the directory svn ran in, to build `absolute_path`
---@return SvenStatusItem[]
function M.parse(lines, root)
  local status = svn.xml.parse(lines):find("status")
  if not status then
    return {}
  end

  local items = {}
  for _, group in ipairs(status.children) do
    local changelist = nil
    if group.tag == "changelist" then
      changelist = group.attrs.name
    end

    if group.tag == "target" or group.tag == "changelist" then
      for _, entry in ipairs(group:all("entry")) do
        local item = parse_entry(entry, changelist, root)
        if item then
          table.insert(items, item)
        end
      end
    end
  end

  return items
end

---Fills in `item.kind`. svn does not report it, so it is taken from disk. Items that are gone
---from disk (deleted, missing) are looked up with one `svn info` call.
---@param items SvenStatusItem[]
---@param cache table<string, string>|nil Kinds known from an earlier run, by item name. Updated in place
---@param opts SvenCliOpts|nil
function M.resolve_kinds(items, cache, opts)
  cache = cache or {}

  local unknown = {}
  for _, item in ipairs(items) do
    local stat = vim.uv.fs_lstat(item.absolute_path)
    if stat then
      item.kind = stat.type == "directory" and "dir" or "file"
    elseif item.status == "unversioned" then
      item.kind = "file"
    elseif cache[item.name] then
      item.kind = cache[item.name]
    else
      table.insert(unknown, item)
    end
  end

  if #unknown > 0 then
    local names = vim.tbl_map(function(item)
      return item.name
    end, unknown)

    local kinds = {}
    local info_opts = svn.cli.opts(opts, { hidden = true, ignore_error = true }) --[[@as SvenInfoOpts]]
    for _, info in ipairs(svn.info.list(names, info_opts)) do
      kinds[(info.path or ""):gsub("\\", "/")] = info.kind
    end

    for _, item in ipairs(unknown) do
      item.kind = kinds[item.name] or "file"
    end
  end

  -- Only items that cannot be inspected on disk are worth remembering
  for name, _ in pairs(cache) do
    cache[name] = nil
  end
  for _, item in ipairs(items) do
    if not vim.uv.fs_lstat(item.absolute_path) then
      cache[item.name] = item.kind
    end
  end
end

---@class SvenStatusFetchOpts: SvenCliOpts
---@field paths? string[] Limit the status to these paths. Defaults to the whole working copy
---@field depth? string "empty"|"files"|"immediates"|"infinity"
---@field no_ignore? boolean Also report ignored files (status "ignored")
---@field kind_cache? table<string, string> See `resolve_kinds`

---Runs `svn status` and parses its output. Needs no network access.
---@param opts SvenStatusFetchOpts|nil
---@return SvenStatusItem[]|nil items nil when svn failed
function M.fetch(opts)
  opts = opts or {}

  local args = { "status", "--xml" }
  if opts.depth then
    vim.list_extend(args, { "--depth", opts.depth })
  end
  if opts.no_ignore then
    table.insert(args, "--no-ignore")
  end

  local cli_opts = svn.cli.opts(opts, { hidden = true, paths = opts.paths })
  local result = svn.cli.run(args, cli_opts)
  if result.code ~= 0 then
    return nil
  end

  local items = M.parse(result.stdout, cli_opts.cwd or svn.repo.root)
  M.resolve_kinds(items, opts.kind_cache, opts)

  return items
end

-- Files svn leaves next to a conflicted file: `<f>.mine`, `<f>.r123`, `<f>.working`,
-- `<f>.merge-left.r1`, `<f>.merge-right.r2` and `<f>.prej` (property conflicts)
local ARTIFACT_SUFFIXES = {
  "%.mine$",
  "%.working$",
  "%.prej$",
  "%.merge%-left%.r%d+$",
  "%.merge%-right%.r%d+$",
  "%.r%d+$",
}

---Whether an unversioned path is one of the files svn creates next to a conflicted file.
---@param name string Path of an unversioned item
---@param conflicted table<string, boolean> Names of the conflicted items
---@return boolean
function M.is_conflict_artifact(name, conflicted)
  for _, suffix in ipairs(ARTIFACT_SUFFIXES) do
    local base, count = name:gsub(suffix, "")
    if count > 0 and conflicted[base] then
      return true
    end
  end

  -- Property conflicts of a directory are described inside it
  local dir = name:match("^(.*)/dir_conflicts%.prej$")
  if name == "dir_conflicts.prej" then
    dir = "."
  end

  return dir ~= nil and conflicted[dir] == true
end

---@param dir string Name of a directory item
---@param name string
---@return boolean whether `name` is below `dir`
local function is_below(dir, name)
  if dir == "." then
    return name ~= "."
  end

  return vim.startswith(name, dir .. "/")
end

---Sorts items into buckets and sets `item.section`.
---
---  1. Anything conflicted goes to `conflicts`, whatever changelist it is in.
---  2. Unversioned items go to `unversioned`, except the files svn puts next to a conflicted file.
---  3. Members of the staging changelist go to `staged`, members of other changelists to
---     `changelists`, the remaining changes to `changes`.
---  4. Changelists hold files only. A directory scheduled for addition is therefore listed (and
---     committed) as staged as soon as a staged file lies below it, because that file cannot be
---     committed without it. A directory scheduled for deletion can only be committed as a whole,
---     so it is staged once all files below it are; `opts.is_fully_staged` answers that.
---     Such directories carry `implied = true`.
---@param items SvenStatusItem[]
---@param opts { staging: string?, is_fully_staged: (fun(item: SvenStatusItem): boolean)? }|nil `staging` defaults to the configured staging changelist
---@return SvenStatusBuckets
function M.bucket(items, opts)
  opts = opts or {}
  local staging = opts.staging or config.get_staging_changelist()

  local buckets = { ---@type SvenStatusBuckets
    conflicts = { items = {} },
    unversioned = { items = {} },
    changes = { items = {} },
    staged = { items = {} },
    changelists = {},
  }

  local conflicted = {}
  for _, item in ipairs(items) do
    if item.conflicted then
      conflicted[item.name] = true
    end
  end

  local changelists = {}
  local function changelist_bucket(name)
    if not changelists[name] then
      changelists[name] = { name = name, items = {} }
      table.insert(buckets.changelists, changelists[name])
    end

    return changelists[name]
  end

  local staged_files = {}
  local changed_dirs = {}

  for _, item in ipairs(items) do
    item.implied = nil

    if item.conflicted then
      item.section = "conflicts"
      table.insert(buckets.conflicts.items, item)
    elseif item.status == "unversioned" then
      if not M.is_conflict_artifact(item.name, conflicted) then
        item.section = "unversioned"
        table.insert(buckets.unversioned.items, item)
      end
    elseif
      item.status == "normal"
      or item.status == "none"
      or item.status == "external"
      or item.status == "ignored"
    then
      -- Nothing to do with these
      item.section = nil
    elseif item.changelist == staging then
      item.section = "staged"
      table.insert(staged_files, item)
    elseif item.changelist then
      item.section = "changelist:" .. item.changelist
      table.insert(changelist_bucket(item.changelist).items, item)
    else
      item.section = "changes"
      if item.kind == "dir" and item.text_status ~= "normal" then
        table.insert(changed_dirs, item)
      end
      table.insert(buckets.changes.items, item)
    end
  end

  -- Directories a commit of the staged files has to include
  local implied = {}
  for _, dir in ipairs(changed_dirs) do
    local has_staged_child = false
    for _, file in ipairs(staged_files) do
      if is_below(dir.name, file.name) then
        has_staged_child = true
        break
      end
    end

    if has_staged_child then
      if dir.status == "added" or dir.status == "replaced" then
        implied[dir] = true
      elseif dir.status == "deleted" and opts.is_fully_staged and opts.is_fully_staged(dir) then
        implied[dir] = true
      end
    end
  end

  if next(implied) then
    buckets.changes.items = vim.tbl_filter(function(item)
      return not implied[item]
    end, buckets.changes.items)
  end

  for _, item in ipairs(items) do
    if implied[item] then
      item.section = "staged"
      item.implied = true
      table.insert(buckets.staged.items, item)
    elseif item.section == "staged" then
      table.insert(buckets.staged.items, item)
    end
  end

  -- svn reports the members of a changelist apart from everything else. Sorting by name puts
  -- the directories back in front of the files inside them.
  table.sort(buckets.staged.items, function(a, b)
    return a.name < b.name
  end)

  table.sort(buckets.changelists, function(a, b)
    return a.name < b.name
  end)

  return buckets
end

---Whether every file below a directory is a member of the staging changelist.
---@param dir SvenStatusItem
---@param opts SvenCliOpts|nil
---@return boolean
function M.is_fully_staged(dir, opts)
  local staging = config.get_staging_changelist()
  local info_opts = svn.cli.opts(opts, { hidden = true, ignore_error = true }) --[[@as SvenInfoOpts]]
  info_opts.depth = "infinity"

  local files = 0
  for _, info in ipairs(svn.info.list({ dir.name }, info_opts)) do
    if info.kind == "file" then
      files = files + 1
      if info.changelist ~= staging then
        return false
      end
    end
  end

  return files > 0
end

---Fetches the status of the whole working copy and sorts it into buckets.
---@param opts SvenStatusFetchOpts|nil
---@return SvenStatusBuckets|nil buckets nil when svn failed
---@return SvenStatusItem[]|nil items Every item svn reported, in its order
function M.buckets(opts)
  local items = M.fetch(opts)
  if not items then
    return nil, nil
  end

  local buckets = M.bucket(items, {
    is_fully_staged = function(dir)
      return M.is_fully_staged(dir, opts)
    end,
  })

  return buckets, items
end

---Calls `fn` for every item of a state (or of buckets), bucket by bucket.
---@param state SvenRepoState|SvenStatusBuckets
---@param fn fun(item: SvenStatusItem, section: string)
function M.each(state, fn)
  for _, section in ipairs { "conflicts", "unversioned", "changes", "staged" } do
    for _, item in ipairs(state[section] and state[section].items or {}) do
      fn(item, section)
    end
  end

  for _, changelist in ipairs(state.changelists or {}) do
    for _, item in ipairs(changelist.items) do
      fn(item, "changelist:" .. changelist.name)
    end
  end
end

---Looks an item up in the state of the current repository
---@param name string Path relative to the working copy root
---@return SvenStatusItem|nil
function M.find(name)
  local found
  M.each(svn.repo.state, function(item)
    if item.name == name then
      found = found or item
    end
  end)

  return found
end

---@return boolean whether anything is staged
function M.anything_staged()
  return #svn.repo.state.staged.items > 0
end

---@return boolean whether there are versioned changes that are not staged
function M.anything_unstaged()
  local state = svn.repo.state
  if #state.changes.items > 0 then
    return true
  end

  for _, changelist in ipairs(state.changelists) do
    if #changelist.items > 0 then
      return true
    end
  end

  return false
end

---@return boolean whether anything is conflicted
function M.any_conflicts()
  return #svn.repo.state.conflicts.items > 0
end

---@return boolean whether the working copy has local changes (unversioned items do not count)
function M.is_dirty()
  return M.anything_staged() or M.anything_unstaged() or M.any_conflicts()
end

---Refreshes the status part of the repository state. Called by `SvenRepo:refresh`.
---@param state SvenRepoState The state being built
---@param filter ItemFilter Items it accepts get a fresh diff, the others keep the one they had
---@param repo SvenRepo
local function update_status(state, filter, repo)
  local previous = {}
  M.each(repo.state, function(item)
    previous[item.name] = item
  end)

  local buckets = M.buckets { cwd = repo.root, kind_cache = repo.kind_cache, hidden = true }
  if not buckets then
    logger.debug("[STATUS] svn status failed - keeping the previous state")
    return
  end

  M.each(buckets, function(item, section)
    local old = previous[item.name]
    if
      old
      and rawget(old, "diff")
      and old.status == item.status
      and old.props == item.props
      and not filter:accepts(section, item.name)
    then
      item.diff = old.diff
    end

    svn.diff.build(item)
  end)

  state.conflicts = buckets.conflicts
  state.unversioned = buckets.unversioned
  state.changes = buckets.changes
  state.staged = buckets.staged
  state.changelists = buckets.changelists
end

---@param meta table<string, function>
M.register = function(meta)
  meta.update_status = update_status
end

return M
