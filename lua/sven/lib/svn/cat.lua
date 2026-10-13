local svn = require("sven.lib.svn")

---`svn cat`
---@class SvenCat
local M = {}

---@class SvenCatOpts: SvenCliOpts
---@field peg? string|number Peg revision: the revision in which `path` is known by that name. Needed for paths that were deleted or moved since

---@param revision string|number
---@return boolean whether the revision can be served from the working copy, without the network
local function is_local(revision)
  return revision == "BASE" or revision == "COMMITTED"
end

---The content of a file in a revision.
---
---  svn.cat.file("src/main.c")          -- the pristine (BASE) content, no network access
---  svn.cat.file("src/main.c", "HEAD")
---  svn.cat.file("^/trunk/old.c", 12, { peg = 12 })
---
---The content is returned byte for byte, including the state of its trailing newline.
---@param path string Path relative to the working copy root, an absolute path, or a URL
---@param revision string|number|nil Defaults to "BASE", which needs no network access
---@param opts SvenCatOpts|nil
---@return string|nil content nil when svn failed
---@return string|nil err The error output of svn
function M.file(path, revision, opts)
  opts = opts or {}
  revision = revision or "BASE"

  local cli_opts = svn.cli.opts(opts, { hidden = true, long = not is_local(revision), raw = true })
  local args = { "cat", "-r", tostring(revision), "--", svn.cli.target(path, opts.peg) }

  local result = svn.cli.run(args, cli_opts)
  if result.code ~= 0 then
    return nil, table.concat(result.stderr, "\n")
  end

  -- Neovim hands NUL bytes of job output over as newlines inside a line
  local lines = result.stdout
  for i, line in ipairs(lines) do
    if line:find("\n", 1, true) then
      lines[i] = line:gsub("\n", "\0")
    end
  end

  return table.concat(lines, "\n"), nil
end

---The content of a file in a revision, by line.
---@param path string Path relative to the working copy root, an absolute path, or a URL
---@param revision string|number|nil Defaults to "BASE"
---@param opts SvenCatOpts|nil
---@return string[]|nil lines nil when svn failed
---@return boolean|string eol Whether the content ends with a newline. The error output of svn on failure
function M.lines(path, revision, opts)
  local content, err = M.file(path, revision, opts)
  if not content then
    return nil, err or ""
  end

  if content == "" then
    return {}, true
  end

  local lines = vim.split(content, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then
    table.remove(lines)
  end

  return lines, eol
end

return M
