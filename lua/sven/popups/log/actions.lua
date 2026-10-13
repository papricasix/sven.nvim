local M = {}

local svn = require("sven.lib.svn")
local util = require("sven.lib.util")
local input = require("sven.lib.input")
local notification = require("sven.lib.notification")
local a = require("sven.lib.async")
local Env = require("sven.popups.diff.env")

---Splits a revision range at its colon. Dates may contain colons of their own:
---`{2026-01-01T12:00}:HEAD`.
---@param revision string
---@return string from
---@return string|nil to nil for a single revision
function M.split_range(revision)
  local depth = 0
  for i = 1, #revision do
    local char = revision:sub(i, i)
    if char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
    elseif char == ":" and depth == 0 then
      return revision:sub(1, i - 1), revision:sub(i + 1)
    end
  end

  return revision, nil
end

---Turns the arguments of the popup into options for `svn.log.list`.
---@param arguments string[] `{ "--limit=256", "--search=fix", "--revision=100:50", "--stop-on-copy" }`
---@return SvenLogOpts
function M.parse_arguments(arguments)
  local opts = { args = {} } ---@type SvenLogOpts

  for _, argument in ipairs(arguments) do
    local name, value = argument:match("^%-%-([%w%-]+)=(.*)$")

    if name == "limit" then
      opts.limit = tonumber(value)
    elseif name == "revision" then
      -- "r42" is how revisions are written everywhere but on the command line
      value = vim.trim(value):gsub("%f[%w][rR](%d+)", "%1")
      if value ~= "" then
        opts.revision = value
      end
    elseif name == "search" then
      if value ~= "" then
        opts.search = opts.search or {}
        table.insert(opts.search --[[@as string[] ]], value)
      end
    elseif argument == "--verbose" then
      opts.verbose = true
    elseif argument == "--stop-on-copy" then
      opts.stop_on_copy = true
    else
      table.insert(opts.args, argument)
    end
  end

  if opts.limit and opts.limit <= 0 then
    opts.limit = nil
  end

  return opts
end

---Whether more history can only be had by asking again with a higher limit.
---
---Usually the next page starts right below the oldest revision that is shown. That does not
---work with `--search`: svn applies the limit before it searches, so there is no telling how far
---back it looked. And it does not work when the range ends in something that is not a number
---(`HEAD:{2026-01-01}`): asking for `41:{2026-01-01}` once revision 42 was the last one in range
---would run the other way.
---@param opts SvenLogOpts
---@return boolean
function M.needs_refetch(opts)
  if opts.search and #opts.search > 0 then
    return true
  end

  if opts.revision then
    local _, to = M.split_range(tostring(opts.revision))
    return to ~= nil and tonumber(to) == nil
  end

  return false
end

---The range of the page that follows the entries that are shown.
---@param revision string|number|nil The range that was asked for. nil for the default: everything, newest first
---@param entries SvenLogEntry[] What is shown
---@return string|nil range nil when there is nothing more
function M.next_range(revision, entries)
  local last = entries[#entries]
  if not last then
    return nil
  end

  if not revision or revision == "" then
    return last.revision > 1 and ("%d:1"):format(last.revision - 1) or nil
  end

  local from, to = M.split_range(tostring(revision))
  local stop = to and tonumber(to)
  if not stop then
    return nil
  end

  local descending = true
  if tonumber(from) then
    descending = tonumber(from) >= stop
  elseif #entries > 1 then
    descending = entries[1].revision > last.revision
  end

  local next_revision = descending and last.revision - 1 or last.revision + 1
  if (descending and next_revision < stop) or (not descending and next_revision > stop) then
    return nil
  end

  return ("%d:%d"):format(next_revision, stop)
end

---Builds the function the log view loads older history with.
---@param opts SvenLogOpts The query the log was fetched with
---@return (fun(entries: SvenLogEntry[]): SvenLogEntry[]|nil, boolean)|nil fetch_more nil when the query has no limit: everything is there
function M.pager(opts)
  local page = opts.limit
  if not page then
    return nil
  end

  -- A single revision has no older history
  if opts.revision and not select(2, M.split_range(tostring(opts.revision))) then
    return nil
  end

  local refetch = M.needs_refetch(opts)
  local searching = opts.search ~= nil and #opts.search > 0
  local limit = page

  return function(entries)
    if refetch then
      local all = svn.log.list(vim.tbl_extend("force", opts, { limit = limit + page }))
      if not all then
        return nil, true
      end

      limit = limit + page
      -- A search may find nothing in a page and still have history left to look at
      return all, searching or #all >= limit
    end

    local range = M.next_range(opts.revision, entries)
    if not range then
      return nil, false
    end

    local more = svn.log.list(vim.tbl_extend("force", opts, { revision = range }))
    if not more then
      return nil, true
    end

    return util.merge(entries, more), #more >= page
  end
end

---Fetches a log and shows it in the log view.
---@param popup PopupData
---@param target { path: string?, peg: string|number|nil, header: string, files: string[]? }
local function show(popup, target)
  local opts = M.parse_arguments(popup:get_arguments())
  opts.path = target.path
  opts.peg = target.peg
  opts.cwd = svn.repo.root

  local entries = svn.log.list(opts)
  a.util.scheduler()

  if not entries then
    -- svn's complaint has been shown already
    return
  end

  local fetch_more = M.pager(opts)
  local searching = opts.search ~= nil and #opts.search > 0

  require("sven.buffers.log_view")
    .new({
      entries = entries,
      header = target.header,
      files = target.files,
      fetch_more = fetch_more,
      has_more = fetch_more ~= nil and (searching or #entries >= opts.limit),
      root = opts.cwd,
    })
    :open()
end

---@return string where The working copy is in the repository: "^/trunk"
local function working_copy_url()
  local prefix = svn.log.working_copy_prefix()
  return prefix and ("^" .. (prefix == "" and "/" or prefix)) or svn.repo.root
end

---The history of the working copy
---@param popup PopupData
function M.log_current(popup)
  show(popup, { header = "Revisions in " .. working_copy_url() })
end

---The history of a file: the one the popup was opened on, or the one of the buffer it was
---opened from
---@param popup PopupData
function M.log_file(popup)
  local file = Env.of(popup).file
  if not file then
    notification.warn("No file to show the history of.")
    return
  end

  show(popup, { path = file, header = "Revisions of " .. file, files = { file } })
end

---The history of the whole repository
---@param popup PopupData
function M.log_repository(popup)
  show(popup, { path = "^/", header = "Revisions in ^/" })
end

---The history of a path or URL that is asked for
---@param popup PopupData
function M.log_other(popup)
  local target = input.get_user_input("Log of path or URL", { completion = "file" })
  if not target then
    return
  end

  target = vim.trim(target)

  local files = nil
  local path = target
  if not target:find("://", 1, true) and not vim.startswith(target, "^/") then
    -- A path: as typed (relative to the current directory), else relative to the working copy root
    local absolute = vim.fn.fnamemodify(target, ":p"):gsub("/+$", "")
    local relative = vim.uv.fs_stat(absolute) and svn.repo:relpath(absolute) or nil
    path = relative or target
    files = path ~= "." and { path } or nil
  end

  show(popup, { path = path, header = "Revisions of " .. path, files = files })
end

return M
