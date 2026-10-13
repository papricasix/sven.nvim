local svn = require("sven.lib.svn")
local config = require("sven.config")
local date = require("sven.lib.svn.date")

---`svn log`. Always contacts the repository.
---@class SvenLog
local M = {}

---@class SvenLogPath
---@field action string "A" added, "D" deleted, "M" modified, "R" replaced
---@field path string Path in the repository, e.g. `/trunk/src/main.c`
---@field kind string "file"|"dir", "" when the server did not say
---@field copyfrom_path string|nil Path the item was copied from
---@field copyfrom_rev number|nil Revision the item was copied from
---@field text_mods boolean|nil
---@field prop_mods boolean|nil

---A log entry. Besides the svn fields it carries the fields Neogit's `CommitLogEntry` has, so
---that `sven.buffers.common.CommitEntry` and views ported from Neogit can render it.
---@class SvenLogEntry
---@field revision number
---@field author string "" when the server did not report one
---@field date string|nil ISO 8601, UTC, e.g. `2026-10-12T20:31:44.107693Z`
---@field message string The complete log message, without trailing newlines
---@field subject string First line of the message
---@field body string The message after its first line, without leading blank lines
---@field description string[] The message, by line
---@field paths SvenLogPath[] Changed paths. Empty unless `verbose` was requested
---@field merged SvenLogEntry[]|nil Revisions merged by this one (only with `--use-merge-history`)
---@field oid string The revision as a string: "42". Use as the `oid` of UI components
---@field abbreviated_commit string "r42"
---@field unix_date number|nil Seconds since the epoch
---@field rel_date string Relative date: "3 days ago"
---@field log_date string Date formatted with `config.log_date_format` (default "%Y-%m-%d %H:%M")
---@field author_name string Same as `author`
---@field author_email string Always ""
---@field author_date string Date formatted with `config.commit_date_format` (default "%Y-%m-%d %H:%M:%S")
---@field committer_name string Same as `author`
---@field committer_email string Always ""
---@field committer_date string Same as `author_date`
---@field ref_name string Always ""

---The name the UI core, which comes from Neogit, knows log entries by
---@alias CommitLogEntry SvenLogEntry

---@param node SvenXmlNode A `logentry` element
---@return SvenLogEntry
local function parse_entry(node)
  local revision = tonumber(node.attrs.revision)
  local author = node:text_of("author") or ""
  local iso = node:text_of("date")
  local message = (node:text_of("msg") or ""):gsub("\r\n", "\n"):gsub("%s+$", "")

  local description = vim.split(message, "\n", { plain = true })
  local subject = description[1] or ""
  local body = table.concat(vim.list_slice(description, 2), "\n"):gsub("^\n+", "")

  local paths = {}
  local paths_node = node:find("paths")
  for _, path in ipairs(paths_node and paths_node:all("path") or {}) do
    table.insert(paths, {
      action = path.attrs.action,
      path = path.text,
      kind = path.attrs.kind or "",
      copyfrom_path = path.attrs["copyfrom-path"],
      copyfrom_rev = tonumber(path.attrs["copyfrom-rev"]),
      text_mods = path.attrs["text-mods"] and path.attrs["text-mods"] == "true" or nil,
      prop_mods = path.attrs["prop-mods"] and path.attrs["prop-mods"] == "true" or nil,
    })
  end

  local merged = nil
  local children = node:all("logentry")
  if #children > 0 then
    merged = vim.tbl_map(parse_entry, children)
  end

  local unix = date.parse(iso)
  local full_date = date.format(unix, config.values.commit_date_format or "%Y-%m-%d %H:%M:%S")

  return {
    revision = revision,
    author = author,
    date = iso,
    message = message,
    subject = subject,
    body = body,
    description = description,
    paths = paths,
    merged = merged,
    oid = tostring(revision),
    abbreviated_commit = "r" .. tostring(revision),
    unix_date = unix,
    rel_date = date.relative(unix),
    log_date = date.format(unix, config.values.log_date_format),
    author_name = author,
    author_email = "",
    author_date = full_date,
    committer_name = author,
    committer_email = "",
    committer_date = full_date,
    ref_name = "",
  }
end

---Parses the output of `svn log --xml`
---@param lines string[]|string
---@return SvenLogEntry[]
function M.parse(lines)
  local log = svn.xml.parse(lines):find("log")
  if not log then
    return {}
  end

  return vim.tbl_map(parse_entry, log:all("logentry"))
end

---@class SvenLogOpts: SvenCliOpts
---@field limit? number Maximum number of entries (`-l`)
---@field path? string Path (relative to the working copy root, or absolute) or URL to show the history of. Defaults to the working copy root
---@field peg? string|number Peg revision: the revision in which `path` is known by that name. Needed for paths that were deleted or moved since
---@field revision? string|number A revision or range (`-r`): 42, "HEAD:1", "100:50", "{2026-01-01}:HEAD". Defaults to "HEAD:1", which unlike svn's own default also shows revisions newer than the working copy
---@field verbose? boolean Include the changed paths of every entry (`-v`)
---@field search? string|string[] Only entries whose author, date, message or (with `verbose`) paths match one of these glob patterns (`--search`)
---@field stop_on_copy? boolean Do not cross copies, i.e. stay on the branch (`--stop-on-copy`)
---@field args? string[] Additional arguments, e.g. `{ "--use-merge-history" }`

---@param opts SvenLogOpts
---@param revision string|number|nil
---@return string[]
local function build_args(opts, revision)
  local args = { "log", "--xml" }

  if opts.limit then
    vim.list_extend(args, { "-l", tostring(opts.limit) })
  end
  if revision then
    vim.list_extend(args, { "-r", tostring(revision) })
  end
  if opts.verbose then
    table.insert(args, "-v")
  end
  if opts.stop_on_copy then
    table.insert(args, "--stop-on-copy")
  end

  local search = opts.search
  if type(search) == "string" then
    search = { search }
  end
  for _, pattern in ipairs(search or {}) do
    if pattern ~= "" then
      vim.list_extend(args, { "--search", pattern })
    end
  end

  vim.list_extend(args, opts.args or {})

  -- The target is added here instead of through `paths`, to be able to give it a peg revision
  local path = svn.cli.relative_paths({ opts.path or "." }, opts.cwd)[1]
  vim.list_extend(args, { "--", svn.cli.target(path, opts.peg) })

  return args
end

---Lists log entries, newest first (unless the revision range says otherwise).
---
---  svn.log.list { limit = 20 }
---  svn.log.list { path = "src/main.c", verbose = true, stop_on_copy = true }
---  svn.log.list { revision = 42, verbose = true }[1]  -- one revision with its changed paths
---@param opts SvenLogOpts|nil
---@return SvenLogEntry[]|nil entries nil when svn failed (offline, no such path, ...)
function M.list(opts)
  opts = opts or {}

  local cli_opts = svn.cli.opts(opts, { long = true })

  if opts.revision then
    local result = svn.cli.run(build_args(opts, opts.revision), cli_opts)
    return result.code == 0 and M.parse(result.stdout) or nil
  end

  -- Starting at HEAD shows what was committed since the last update, including one's own
  -- commits, which svn's default (the base revision of the path) hides. It fails for paths that
  -- no longer exist in HEAD, so fall back to the default then.
  local function gone_in_head(res)
    local stderr = table.concat(res.stderr, "\n")
    return stderr:match("E160013") ~= nil or stderr:match("E195012") ~= nil
  end

  local head_opts = vim.tbl_extend("force", {}, cli_opts)
  head_opts.on_error = function(res)
    if gone_in_head(res) then
      return false
    end

    if cli_opts.on_error then
      return cli_opts.on_error(res)
    end

    return not cli_opts.ignore_error
  end

  local result = svn.cli.run(build_args(opts, "HEAD:1"), head_opts)
  if result.code == 0 then
    return M.parse(result.stdout)
  elseif not gone_in_head(result) then
    return nil
  end

  result = svn.cli.run(build_args(opts, nil), cli_opts)
  return result.code == 0 and M.parse(result.stdout) or nil
end

---A single revision, with its changed paths.
---@param revision string|number
---@param opts SvenLogOpts|nil `path` defaults to the working copy root; use `"^/"` to see every path the revision changed
---@return SvenLogEntry|nil
function M.revision(revision, opts)
  local entries = M.list(vim.tbl_extend("force", { verbose = true }, opts or {}, { revision = revision }))
  return entries and entries[1] or nil
end

---Where the working copy sits in the repository: the path its root was checked out from.
---Log entries and diffs of whole revisions name paths in the repository (`/trunk/src/main.c`);
---this is what it takes to tell which of them are in the working copy (see `working_copy_path`).
---@param opts SvenCliOpts|nil `cwd` selects the working copy, the current one by default
---@return string|nil prefix "/trunk", or "" for a checkout of the repository root. nil when svn has no answer
function M.working_copy_prefix(opts)
  local root = opts and opts.cwd or svn.repo.root
  if not root or root == "" then
    return nil
  end

  local info = require("sven.lib.svn.repository").find(root).state.info
  if not info or not info.relative_url then
    info = svn.info.get(".", svn.cli.opts(opts, { cwd = root, hidden = true, ignore_error = true }))
  end

  if not info or not info.relative_url then
    return nil
  end

  local prefix = vim.uri_decode(info.relative_url):gsub("^%^", ""):gsub("/+$", "")
  return prefix
end

---Maps a path in the repository to the working copy.
---
---  local prefix = svn.log.working_copy_prefix()            -- "/trunk"
---  svn.log.working_copy_path("/trunk/src/main.c", prefix)  -- "src/main.c"
---  svn.log.working_copy_path("/branches/x/a.txt", prefix)  -- nil
---@param path string Path in the repository: `/trunk/a.txt` as in log entries, `trunk/a.txt` as in diffs of `^/`, or `^/trunk/a.txt`
---@param prefix string|nil See `working_copy_prefix`
---@return string|nil relative Path relative to the working copy root ("." for the root itself). nil for paths outside the working copy
function M.working_copy_path(path, prefix)
  if not prefix then
    return nil
  end

  path = path:gsub("^%^", "")
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end

  if path == prefix or path == prefix .. "/" then
    return "."
  end

  if vim.startswith(path, prefix .. "/") then
    return path:sub(#prefix + 2)
  end

  return nil
end

return M
