---Throwaway Subversion repositories and working copies for specs.
---
---  local harness = require("tests.util.svn_harness")
---
---  describe("something", function()
---    local wc
---
---    before_each(function()
---      wc = harness.create()   -- repository + working copy of its trunk, made the current one
---    end)
---
---    after_each(function()
---      harness.cleanup()
---    end)
---
---    it("sees a modification", function()
---      wc:write("a.txt", "changed\n")
---      local state = wc:refresh()
---      assert.are.same("a.txt", state.changes.items[1].name)
---    end)
---  end)
---
---The trunk of a fresh repository contains (revision 2):
---
---  a.txt            20 lines: "line 1" .. "line 20"
---  b.txt            "hello\n"
---  noeol.txt        "no newline at the end" (no trailing newline)
---  src/main.c       a few lines of C
---  src/sub/util.c   a few lines of C
---  docs/readme.md   two lines
---
---Everything lives below a temporary directory. svn runs with a configuration directory of its
---own, so the configuration of whoever runs the specs (auto-props, global ignores) cannot
---influence them.
local util = require("tests.util.util")

local M = {}

---@type string|nil Directory holding the svn wrapper and its configuration
local tool_dir = nil

---@type string[] Directories to remove on cleanup
local created = {}

-- After an operation that writes working files, svn sleeps until the clock reaches the next
-- timestamp it can tell apart from the one it recorded (a full second with many builds), so that
-- a later modification cannot go unnoticed. That adds up to minutes over the specs. The harness
-- turns the sleep off, with the switch svn's own test suite uses, and makes up for it: every
-- file it writes gets a modification time of its own (see `touch`), which svn has never recorded
-- for any file. So svn always takes a closer look at what a spec changed.
--
-- Change files through the working copy helpers (`write`, `append`, `replace`), not behind
-- their back, or svn may not notice a change that leaves the size of a file as it was.
local NO_SLEEP = "SVN_I_LOVE_CORRUPTED_WORKING_COPIES_SO_DISABLE_SLEEP_FOR_TIMESTAMPS"
vim.env[NO_SLEEP] = "yes"

local fake_time = os.time() + 1000000

---Gives a file a modification time that no other file has, and that svn has never recorded
---@param path string
local function touch(path)
  fake_time = fake_time + 1
  vim.uv.fs_utime(path, fake_time, fake_time)
end

---The svn executable used by the harness and by sven during specs: a wrapper that pins the
---configuration directory.
---@return string
function M.executable()
  if tool_dir then
    return tool_dir .. "/svn"
  end

  tool_dir = util.create_temp_dir()

  local real = vim.fn.exepath("svn")
  assert(real ~= "", "svn executable not found")

  local config_dir = tool_dir .. "/config"
  vim.fn.mkdir(config_dir, "p")

  util.write_file(
    tool_dir .. "/svn",
    table.concat({
      "#!/bin/sh",
      ('exec %s --config-dir %s "$@"'):format(vim.fn.shellescape(real), vim.fn.shellescape(config_dir)),
      "",
    }, "\n")
  )
  vim.uv.fs_chmod(tool_dir .. "/svn", 493) -- 0755

  return tool_dir .. "/svn"
end

---Runs svn directly (not through sven) and returns its output. Errors when svn fails.
---@param args string[]
---@param cwd string|nil
---@param opts { ignore_err: boolean? }|nil
---@return string stdout
---@return number code
function M.svn(args, cwd, opts)
  local cmd = { M.executable(), "--non-interactive" }
  vim.list_extend(cmd, args)

  return util.system(cmd, { cwd = cwd, ignore_err = opts and opts.ignore_err, env = { LC_MESSAGES = "C" } })
end

---Sets sven up for specs: default configuration, the svn wrapper of the harness, no file watcher.
---Safe to call repeatedly.
---@param opts SvenConfig|nil Extra configuration
function M.setup(opts)
  local values = vim.tbl_deep_extend("force", {
    svn_executable = M.executable(),
    filewatcher = { enabled = false },
    remember_settings = false,
  }, opts or {})

  -- Only the first call really sets sven up. Later ones start over from the defaults.
  local config = require("sven.config")
  config.values = config.get_default_values()
  require("sven").setup(vim.deepcopy(values))

  config.values = config.get_default_values()
  config.setup(values)
end

---A working copy
---@class SvnHarnessWorkingCopy
---@field path string Absolute path of the working copy root
---@field url string URL the working copy was checked out from (the trunk)
---@field repo_url string URL of the repository root
---@field base string Temporary directory the repository and its working copies live in
local WorkingCopy = {}
WorkingCopy.__index = WorkingCopy

---@param relative string|nil Path relative to the working copy root
---@return string absolute
function WorkingCopy:abs(relative)
  if not relative or relative == "" or relative == "." then
    return self.path
  end

  return self.path .. "/" .. relative
end

---Runs svn in the working copy, directly (not through sven)
---@param ... string Arguments
---@return string stdout
function WorkingCopy:svn(...)
  return (M.svn({ ... }, self.path))
end

---Writes a file (creating directories as needed), without telling svn
---@param relative string
---@param content string
function WorkingCopy:write(relative, content)
  util.write_file(self:abs(relative), content)
  touch(self:abs(relative))
end

---@param relative string
---@param content string
function WorkingCopy:append(relative, content)
  self:write(relative, self:read(relative) .. content)
end

---@param relative string
---@return string content
function WorkingCopy:read(relative)
  return util.read_file(self:abs(relative))
end

---@param relative string
---@return boolean
function WorkingCopy:exists(relative)
  return vim.uv.fs_lstat(self:abs(relative)) ~= nil
end

---Replaces the first occurrence of `old` (plain text) in a file
---@param relative string
---@param old string
---@param new string
function WorkingCopy:replace(relative, old, new)
  local content = self:read(relative)
  local from, to = content:find(old, 1, true)
  assert(from, ("%q not found in %s"):format(old, relative))

  self:write(relative, content:sub(1, from - 1) .. new .. content:sub(to + 1))
end

---Creates a directory, without telling svn
---@param relative string
function WorkingCopy:mkdir(relative)
  vim.fn.mkdir(self:abs(relative), "p")
end

---Removes a file or directory from disk, without telling svn: the path becomes "missing"
---@param relative string
function WorkingCopy:remove(relative)
  vim.fn.delete(self:abs(relative), "rf")
end

---Paths as svn wants them: an `@` in a name has to be followed by another one at the end, or svn
---takes what follows it for a peg revision.
---@param ... string Paths
---@return string ...
local function targets(...)
  local result = {}
  for _, path in ipairs { ... } do
    table.insert(result, path:find("@", 1, true) and (path .. "@") or path)
  end

  return unpack(result)
end

---`svn add`
---@param ... string Paths
function WorkingCopy:add(...)
  self:svn("add", "--parents", "--", targets(...))
end

---`svn delete`
---@param ... string Paths
function WorkingCopy:delete(...)
  self:svn("delete", "--", targets(...))
end

---`svn changelist`
---@param name string
---@param ... string Paths
function WorkingCopy:changelist(name, ...)
  self:svn("changelist", name, "--", targets(...))
end

---`svn propset`
---@param name string
---@param value string
---@param relative string
function WorkingCopy:propset(name, value, relative)
  self:svn("propset", name, value, "--", targets(relative))
end

---Commits everything (or the given paths) directly with svn
---@param message string
---@param ... string Paths
---@return number revision
function WorkingCopy:commit(message, ...)
  local out = self:svn("commit", "-m", message, "--", targets(...))
  return assert(tonumber(out:match("Committed revision (%d+)%.")), "Nothing was committed:\n" .. out)
end

---`svn update --accept postpone`
---@return string stdout
function WorkingCopy:update()
  return self:svn("update", "--accept", "postpone")
end

---The output of `svn status` as lines, sorted, for assertions:
---`{ "?       new.txt", "M       a.txt" }`
---@return string[]
function WorkingCopy:status()
  local lines = vim.split(self:svn("status"), "\n", { trimempty = true })
  table.sort(lines)

  return lines
end

---The status letters of a path as printed by `svn status` ("M", "A", "?", ...), "" when svn has
---nothing to report about it
---@param relative string
---@return string
function WorkingCopy:status_of(relative)
  local out = self:svn("status", "--depth", "empty", "--", targets(relative))
  for _, line in ipairs(vim.split(out, "\n", { trimempty = true })) do
    if not line:match("^%-%-%- Changelist") and line:sub(9) == relative then
      return vim.trim(line:sub(1, 7))
    end
  end

  return ""
end

---The members of a changelist, sorted
---@param name string
---@return string[]
function WorkingCopy:members(name)
  local xml = require("sven.lib.svn.xml")
  local doc = xml.parse(self:svn("status", "--xml"))

  local members = {}
  for _, changelist in ipairs(doc:find("status"):all("changelist")) do
    if changelist.attrs.name == name then
      for _, entry in ipairs(changelist:all("entry")) do
        table.insert(members, entry.attrs.path)
      end
    end
  end
  table.sort(members)

  return members
end

---The newest revision of the repository
---@return number
function WorkingCopy:head()
  return assert(tonumber(vim.trim((M.svn({ "info", "--show-item", "revision", self.repo_url }, self.path)))))
end

---The log message of a revision
---@param revision number|string
---@return string
function WorkingCopy:log_message(revision)
  local out = M.svn({ "log", "--xml", "-r", tostring(revision), self.repo_url }, self.path)
  local entry = require("sven.lib.svn.xml").parse(out):path("log", "logentry")

  return entry and entry:text_of("msg") or ""
end

---The paths a revision changed, as "<action> <path>", sorted: `{ "A /trunk/new.txt" }`
---@param revision number|string
---@return string[]
function WorkingCopy:changed_paths(revision)
  local out = M.svn({ "log", "--xml", "-v", "-r", tostring(revision), self.repo_url }, self.path)
  local entry = require("sven.lib.svn.xml").parse(out):path("log", "logentry")

  local paths = {}
  for _, path in ipairs(entry and entry:path("paths"):all("path") or {}) do
    table.insert(paths, ("%s %s"):format(path.attrs.action, path.text))
  end
  table.sort(paths)

  return paths
end

---Makes this working copy the current one of sven: `require("sven.lib.svn").repo` is its repository
---@return SvenRepo
function WorkingCopy:use()
  return require("sven.lib.svn.repository").instance(self.path)
end

---The repository instance of this working copy
---@return SvenRepo
function WorkingCopy:repo()
  return require("sven.lib.svn.repository").find(self.path)
end

---Refreshes the repository state of this working copy and waits for it
---@param opts SvenRefreshOpts|nil
---@return SvenRepoState
function WorkingCopy:refresh(opts)
  local repo = self:repo()

  local done = false
  repo:refresh(vim.tbl_extend("force", opts or {}, {
    source = "harness",
    callback = function()
      done = true
    end,
  }))

  local finished = util.wait_for(function()
    return done
  end, 10000)
  assert(finished, "Refresh did not finish in time")

  return repo.state
end

---Waits for the recent log entries of this working copy, which are fetched in the background
---@return SvenLogEntry[]
function WorkingCopy:wait_for_recent()
  local repo = self:repo()
  util.wait_for(function()
    return not repo.recent.loading
  end, 10000)

  return repo.recent.items
end

---Checks out a second working copy of the same URL, to manufacture incoming changes and conflicts
---@param name string|nil Directory name, defaults to "wc2"
---@return SvnHarnessWorkingCopy
function WorkingCopy:checkout(name)
  name = name or "wc2"
  local path = self.base .. "/" .. name

  M.svn({ "checkout", "-q", self.url, path }, self.base)

  local other = { path = path, url = self.url, repo_url = self.repo_url, base = self.base }
  return setmetatable(other, WorkingCopy)
end

---@class SvnHarnessOpts
---@field setup? boolean Set sven up for specs first (default true)
---@field use? boolean Make the working copy the current one (default true)
---@field empty? boolean Leave the trunk empty instead of committing the standard files

---@param base string Directory to create the repository and the working copy in
---@return SvnHarnessWorkingCopy
local function working_copy(base)
  local repo_url = "file://" .. base .. "/repo"

  return setmetatable({
    path = base .. "/wc",
    url = repo_url .. "/trunk",
    repo_url = repo_url,
    base = base,
  }, WorkingCopy)
end

---Creates a repository with an empty trunk, and a working copy of it
---@param base string
---@return SvnHarnessWorkingCopy
local function create_empty(base)
  local wc = working_copy(base)

  util.system { "svnadmin", "create", base .. "/repo" }
  M.svn({ "mkdir", "-q", "-m", "Create the layout", wc.url, wc.repo_url .. "/branches" }, base)
  M.svn({ "checkout", "-q", wc.url, wc.path }, base)

  return wc
end

---@type SvnHarnessWorkingCopy|nil The repository and working copy every fixture is a copy of
local template = nil

---Builds the standard repository once per Neovim instance. Copying it is a lot quicker than
---running the half dozen svn commands it takes to build.
---@return SvnHarnessWorkingCopy
local function get_template()
  if template then
    return template
  end

  local wc = create_empty(util.create_temp_dir())

  local lines = {}
  for i = 1, 20 do
    table.insert(lines, "line " .. i)
  end

  wc:write("a.txt", table.concat(lines, "\n") .. "\n")
  wc:write("b.txt", "hello\n")
  wc:write("noeol.txt", "no newline at the end")
  wc:write("src/main.c", "#include <stdio.h>\n\nint main(void) {\n  return 0;\n}\n")
  wc:write("src/sub/util.c", "int add(int a, int b) {\n  return a + b;\n}\n")
  wc:write("docs/readme.md", "# Readme\n\nSome text.\n")

  wc:add("a.txt", "b.txt", "noeol.txt", "src", "docs")
  wc:commit("Add the initial files")
  wc:update()

  template = wc
  return template
end

---Creates a repository with a trunk, and a working copy of that trunk.
---@param opts SvnHarnessOpts|nil
---@return SvnHarnessWorkingCopy
function M.create(opts)
  opts = opts or {}

  if opts.setup ~= false then
    M.setup()
  end

  local base = util.create_temp_dir()
  table.insert(created, base)

  local wc
  if opts.empty then
    wc = create_empty(base)
  else
    local source = get_template()
    wc = working_copy(base)

    -- `-p` keeps the modification times, which have to match what the working copy recorded
    util.system { "cp", "-Rp", source.base .. "/repo", base .. "/repo" }
    util.system { "cp", "-Rp", source.path, wc.path }
    M.svn({ "relocate", source.repo_url, wc.repo_url }, wc.path)
  end

  if opts.use ~= false then
    wc:use()
  end

  return wc
end

---Blocks until sven has nothing left to do in any working copy: no refresh running and no recent
---log entries being fetched.
function M.settle()
  local Repo = require("sven.lib.svn.repository")

  util.wait_for(function()
    for _, repo in ipairs(Repo.all()) do
      if repo:busy() then
        return false
      end
    end

    return true
  end, 10000)
end

---Removes everything the harness created. Waits for background work of sven first, so that
---nothing runs svn in a directory that is gone.
function M.cleanup()
  M.settle()

  for _, dir in ipairs(created) do
    vim.fn.delete(dir, "rf")
  end

  created = {}
end

return M
