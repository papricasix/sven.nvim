local svn = require("sven.lib.svn")

---`svn info`
---@class SvenInfo
local M = {}

---@class SvenInfoConflict
---@field type string "text"|"property"|"tree"
---@field operation string|nil "update"|"switch"|"merge"
---@field action string|nil Tree conflicts: incoming action
---@field reason string|nil Tree conflicts: local reason
---@field base_file string|nil Text conflicts: path of the common ancestor (`<f>.r3`)
---@field mine_file string|nil Text conflicts: path of the local version (`<f>.mine`)
---@field theirs_file string|nil Text conflicts: path of the incoming version (`<f>.r5`)
---@field prop_file string|nil Property conflicts: path of the reject file

---@class SvenInfoEntry
---@field path string The path as svn printed it (relative to the directory svn ran in)
---@field kind string "file"|"dir"
---@field url string|nil Full URL, e.g. `https://host/repo/trunk`
---@field relative_url string|nil URL relative to the repository root, e.g. `^/trunk`
---@field repos_root string|nil URL of the repository root
---@field uuid string|nil Repository UUID
---@field wc_root string|nil Absolute path of the working copy root
---@field revision number|nil Revision of the node (the BASE revision for working copy paths)
---@field last_changed_rev number|nil Revision the node was last changed in
---@field last_changed_author string|nil
---@field last_changed_date string|nil ISO 8601, UTC
---@field schedule string|nil "normal"|"add"|"delete"|"replace"
---@field depth string|nil "infinity"|"files"|"immediates"|"empty"
---@field changelist string|nil The changelist a file is a member of
---@field conflicts SvenInfoConflict[] Empty unless the node is conflicted

---@param entry SvenXmlNode
---@return SvenInfoEntry
local function parse_entry(entry)
  local repository = entry:find("repository")
  local wc_info = entry:find("wc-info")
  local commit = entry:find("commit")

  local conflicts = {}
  for _, conflict in ipairs(entry:all("conflict")) do
    table.insert(conflicts, {
      type = conflict.attrs.type,
      operation = conflict.attrs.operation,
      base_file = conflict:text_of("prev-base-file"),
      mine_file = conflict:text_of("prev-wc-file"),
      theirs_file = conflict:text_of("cur-base-file"),
      prop_file = conflict:text_of("prop-file"),
    })
  end

  for _, conflict in ipairs(entry:all("tree-conflict")) do
    table.insert(conflicts, {
      type = "tree",
      operation = conflict.attrs.operation,
      action = conflict.attrs.action,
      reason = conflict.attrs.reason,
    })
  end

  return {
    path = entry.attrs.path,
    kind = entry.attrs.kind,
    revision = tonumber(entry.attrs.revision),
    url = entry:text_of("url"),
    relative_url = entry:text_of("relative-url"),
    repos_root = repository and repository:text_of("root") or nil,
    uuid = repository and repository:text_of("uuid") or nil,
    wc_root = wc_info and wc_info:text_of("wcroot-abspath") or nil,
    schedule = wc_info and wc_info:text_of("schedule") or nil,
    depth = wc_info and wc_info:text_of("depth") or nil,
    changelist = wc_info and wc_info:text_of("changelist") or nil,
    last_changed_rev = commit and tonumber(commit.attrs.revision) or nil,
    last_changed_author = commit and commit:text_of("author") or nil,
    last_changed_date = commit and commit:text_of("date") or nil,
    conflicts = conflicts,
  }
end

---Parses the output of `svn info --xml`
---@param lines string[]|string
---@return SvenInfoEntry[]
function M.parse(lines)
  local root = svn.xml.parse(lines)
  local info = root:find("info")
  if not info then
    return {}
  end

  return vim.tbl_map(parse_entry, info:all("entry"))
end

---@class SvenInfoOpts: SvenCliOpts
---@field revision? string|number Ask the repository about this revision instead of the working copy (network)
---@field depth? string "empty" (default) | "files" | "immediates" | "infinity"

---Information about several paths, in one svn invocation.
---Paths that svn knows nothing about (unversioned) are simply missing from the result.
---@param paths string[] Paths relative to the working copy root, absolute paths, or URLs
---@param opts SvenInfoOpts|nil
---@return SvenInfoEntry[]
function M.list(paths, opts)
  opts = opts or {}

  local args = { "info", "--xml" }
  if opts.revision then
    vim.list_extend(args, { "-r", tostring(opts.revision) })
  end
  if opts.depth then
    vim.list_extend(args, { "--depth", opts.depth })
  end

  local result = svn.cli.run(args, svn.cli.opts(opts, { hidden = true, paths = paths }))

  -- svn reports the paths it knows even when it fails for some of the others
  return M.parse(result.stdout)
end

---Information about one path.
---
---  local info = svn.info.get()             -- the working copy root
---  info.relative_url                       -- "^/trunk"
---  svn.info.get("src/main.c").last_changed_rev
---@param path string|nil Path relative to the working copy root, an absolute path, or a URL. Defaults to the working copy root
---@param opts SvenInfoOpts|nil
---@return SvenInfoEntry|nil info nil when svn knows nothing about the path
function M.get(path, opts)
  return M.list({ path or "." }, opts)[1]
end

return M
