local svn = require("sven.lib.svn")

---`svn blame`. Always contacts the repository.
---@class SvenBlame
local M = {}

---@class SvenBlameLine
---@field line number Line number, starting at 1
---@field revision number|nil Revision that last changed the line. nil for lines with uncommitted local changes
---@field author string|nil
---@field date string|nil ISO 8601, UTC
---@field merged { revision: number|nil, author: string|nil, date: string|nil, path: string|nil }|nil Origin of the line, with `--use-merge-history`

---Parses the output of `svn blame --xml`
---@param lines string[]|string
---@return SvenBlameLine[]
function M.parse(lines)
  local blame = svn.xml.parse(lines):find("blame")
  local target = blame and blame:find("target")
  if not target then
    return {}
  end

  local result = {}
  for _, entry in ipairs(target:all("entry")) do
    local commit = entry:find("commit")
    local merged = entry:find("merged")
    local merged_commit = merged and merged:find("commit")

    table.insert(result, {
      line = tonumber(entry.attrs["line-number"]) or (#result + 1),
      revision = commit and tonumber(commit.attrs.revision) or nil,
      author = commit and commit:text_of("author") or nil,
      date = commit and commit:text_of("date") or nil,
      merged = merged_commit and {
        revision = tonumber(merged_commit.attrs.revision),
        author = merged_commit:text_of("author"),
        date = merged_commit:text_of("date"),
        path = merged.attrs.path,
      } or nil,
    })
  end

  return result
end

---@class SvenBlameOpts: SvenCliOpts
---@field peg? string|number Peg revision of `path`
---@field args? string[] Additional arguments, e.g. `{ "-x", "-w" }` to ignore whitespace or `{ "--use-merge-history" }`

---Who last changed each line of a file.
---
---Without `revision` this blames the working file, as `svn blame` does: the result has one entry
---per line of the file on disk, and lines with uncommitted changes have no revision. With a
---revision the entries describe the file as of that revision (`svn.cat.file(path, revision)` is
---the matching content).
---@param path string Path relative to the working copy root, an absolute path, or a URL
---@param revision string|number|nil Blame the file as of this revision (`-r`), e.g. "BASE", "HEAD", 42
---@param opts SvenBlameOpts|nil
---@return SvenBlameLine[]|nil lines nil when svn failed (offline, binary file, ...)
---@return string|nil err The error output of svn
function M.file(path, revision, opts)
  opts = opts or {}

  local args = { "blame", "--xml" }
  if revision then
    vim.list_extend(args, { "-r", tostring(revision) })
  end
  vim.list_extend(args, opts.args or {})
  vim.list_extend(args, { "--", svn.cli.target(path, opts.peg) })

  local result = svn.cli.run(args, svn.cli.opts(opts, { long = true }))
  if result.code ~= 0 then
    return nil, table.concat(result.stderr, "\n")
  end

  local lines = M.parse(result.stdout)

  -- svn skips a binary file with a warning, and calls that a success
  if #lines == 0 then
    local warning = vim.trim(table.concat(result.stderr, "\n"))
    if warning ~= "" then
      return nil, warning
    end
  end

  return lines, nil
end

return M
