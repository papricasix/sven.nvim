local svn = require("sven.lib.svn")
local process = require("sven.process")
local runner = require("sven.runner")
local config = require("sven.config")
local notification = require("sven.lib.notification")

---Low level access to the svn executable.
---
---Every command runs through `sven.process`, so it shows up in the command history buffer and
---drives the console and the spinner. Calling convention, shared by everything in `sven.lib.svn`
---that runs svn:
---
---  * Inside a `sven.lib.async` context (`a.void(function() ... end)()`, popup actions, mappings
---    created with `a.void`) the coroutine is suspended while svn runs. Neovim stays responsive.
---  * Outside of one, or with `await = true`, Neovim blocks until svn exits.
---
---Either way the call returns the result, there are no callbacks.
---
---svn is always run with `--non-interactive` and a closed stdin: it can never wait for a prompt.
---Credentials must be cached (or provided by an agent/keychain) beforehand.
---@class SvenCli
---@field history ProcessResult[] Every command that was run, see `sven.buffers.command_history`
local M = {}

M.history = runner.history

---@class SvenCliOpts
---@field hidden? boolean Hide the command from the command history and never show the console for it. Use for commands the user did not ask for (status refreshes, diffs). A hidden command that fails is listed after all, unless `ignore_error` is set
---@field await? boolean Block Neovim until svn exits, also inside an async context
---@field input? string Sent to the stdin of svn, which is closed afterwards
---@field ignore_error? boolean Do not notify the user when svn exits with a non-zero code
---@field cwd? string Directory to run in. Defaults to the root of the current working copy
---@field env? table<string, string> Extra environment variables
---@field long? boolean The command is expected to run for a long time (network): do not pop up the console after `console_timeout`
---@field user_command? boolean The command was typed by the user: when the console is showing its output, leave it open after the command succeeded
---@field raw? boolean Keep `stdout`/`stderr` exactly as produced: `table.concat(stdout, "\n")` is then the exact output, i.e. the last element is "" when the output ended with a newline. By default that trailing empty element is removed
---@field trim? boolean Remove every blank line from `stdout` and `stderr`
---@field on_error? fun(res: SvenCliResult): boolean Called when svn fails. Return false to suppress the notification
---@field paths? string[] Paths (relative to `cwd`, or absolute) appended after `--`. A trailing `@` is added where needed, so that an `@` in a file name is not taken for a peg revision
---@field verbatim_paths? boolean Do not add that `@`. Needed for exactly one case: `svn diff` of the working copy against its base takes its paths literally (see `sven.lib.svn.diff`)

---@class SvenCliResult: ProcessResult
---@field code number Exit code
---@field stdout string[] Lines written to stdout
---@field stderr string[] Lines written to stderr
---@field time number Duration in milliseconds
---@field cmd string The command line
---@field hidden boolean|nil

---@return string
function M.executable()
  return config.get_svn_executable()
end

---Environment for every svn invocation.
---
---Messages are forced to the C locale so that output we have to parse ("Committed revision 3.",
---"(working copy)", "Property changes on:") is not translated. Only `LC_MESSAGES` is changed:
---`LC_ALL=C` would also switch the character set and make svn fail on non-ASCII paths.
---@return table<string, string>
function M.env()
  local env = { LC_MESSAGES = "C" }

  -- LC_ALL overrides LC_MESSAGES. Demote it to the categories that matter for paths.
  local lc_all = vim.env.LC_ALL
  if lc_all and lc_all ~= "" then
    env.LC_ALL = ""
    env.LC_CTYPE = lc_all
  end

  return env
end

---Formats a path as an svn target: appends `@` (and the peg revision) when necessary, so that a
---file called `icon@2x.png` is not read as `icon` at peg revision `2x.png`.
---@param path string
---@param peg string|number|nil Peg revision
---@return string
function M.target(path, peg)
  if peg ~= nil and peg ~= "" then
    return ("%s@%s"):format(path, peg)
  end

  if path:find("@", 1, true) then
    return path .. "@"
  end

  return path
end

---@param paths string[]
---@return string[]
function M.targets(paths)
  return vim.tbl_map(function(path)
    return M.target(path)
  end, paths)
end

---Makes absolute paths inside a working copy relative to its root. Everything else (relative
---paths, URLs, `^/` paths, paths outside the working copy) is returned unchanged.
---
---svn echoes paths the way they were given, and sven identifies items by their path relative to
---the working copy root, so every path handed to svn goes through this.
---@param paths string[]
---@param root string|nil Working copy root. Defaults to the root of the current working copy. Paths are left alone when this is not the root of a working copy
---@return string[]
function M.relative_paths(paths, root)
  local repo
  if root and root ~= "" then
    repo = require("sven.lib.svn.repository").find(root)

    local real = vim.uv.fs_realpath(root)
    if repo.root == "" or not real or vim.fs.normalize(real) ~= repo.root then
      return paths
    end
  else
    repo = svn.repo
  end

  return vim.tbl_map(function(path)
    local is_absolute = path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
    if is_absolute and not path:find("://", 1, true) then
      return repo:relpath(path) or path
    end

    return path
  end, paths)
end

---Finds the root of the working copy a directory belongs to. Does not go through the command
---history. Works for unversioned directories inside a working copy as well.
---@param dir string
---@return string root Absolute path with symlinks resolved, "" when `dir` is not inside a working copy
function M.wc_root(dir)
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))

  -- Since svn 1.7 only the root of a working copy has an administrative directory. Looking for
  -- it first avoids spawning svn outside of working copies.
  local admin = vim.fs.find(".svn", { path = dir, upward = true, type = "directory", limit = 1 })[1]
  if not admin then
    return ""
  end

  local candidate = vim.fs.dirname(admin)
  local ok, result = pcall(function()
    local cmd = {
      M.executable(),
      "--non-interactive",
      "info",
      "--show-item",
      "wc-root",
      "--no-newline",
      "--",
      M.target(candidate),
    }
    -- The directory is given explicitly: Neovim's own working directory may be gone
    return vim.system(cmd, { text = true, env = M.env(), cwd = candidate }):wait()
  end)

  if not ok or result.code ~= 0 then
    return ""
  end

  local root = vim.trim(result.stdout or "")
  if root == "" then
    return ""
  end

  return vim.fs.normalize(vim.uv.fs_realpath(root) or root)
end

---@param dir string
---@return boolean
function M.is_inside_working_copy(dir)
  return M.wc_root(dir) ~= ""
end

---@param lines string[]
---@return string[]
local function drop_trailing_empty(lines)
  if lines[#lines] == "" then
    lines[#lines] = nil
  end

  return lines
end

---A result for commands that could not be started at all
---@param cmd string[]
---@param message string
---@return SvenCliResult
local function failed_result(cmd, message)
  local result = {
    code = 127,
    stdout = {},
    stderr = { message },
    output = {},
    time = 0,
    cmd = table.concat(cmd, " "),
  }

  function result:success()
    return false
  end

  function result:failure()
    return true
  end

  return result
end

---Builds the argument vector svn is invoked with.
---@param args string[] Subcommand and its arguments, e.g. `{ "status", "--xml" }`
---@param paths string[]|nil
---@param verbatim boolean|nil Pass the paths as they are, see `SvenCliOpts.verbatim_paths`
---@return string[]
function M.command(args, paths, verbatim)
  local cmd = { M.executable(), "--non-interactive" }
  vim.list_extend(cmd, args)

  if paths and #paths > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, verbatim and paths or M.targets(paths))
  end

  return cmd
end

---Runs svn.
---
---  local result = svn.cli.run({ "status", "--xml" }, { hidden = true })
---  if result.code == 0 then ... result.stdout ... end
---
---  svn.cli.run({ "add", "--parents" }, { paths = { "new dir/icon@2x.png" }, await = true })
---
---A failing command (non-zero exit) is reported to the user with the tail of its stderr, unless
---`ignore_error` is set or `on_error` returns false. The result is returned in both cases.
---@param args string[] Subcommand and its arguments. `--non-interactive` is added for you
---@param opts SvenCliOpts|nil
---@return SvenCliResult
function M.run(args, opts)
  opts = opts or {}

  local cwd = opts.cwd
  if not cwd or cwd == "" then
    cwd = svn.repo.root
  end
  if cwd == "" then
    cwd = nil
  end

  local paths = opts.paths
  if paths and #paths > 0 and cwd then
    paths = M.relative_paths(paths, cwd)
  end

  local cmd = M.command(args, paths, opts.verbatim_paths)

  -- Starting a job that cannot run raises. Report it like any other failure instead.
  local unable
  if vim.fn.executable(cmd[1]) ~= 1 then
    unable = ("svn executable %q not found. Set `svn_executable` in the sven config."):format(cmd[1])
  elseif cwd and vim.fn.isdirectory(cwd) ~= 1 then
    unable = ("Directory %q does not exist anymore"):format(cwd)
  end

  if unable then
    if not opts.ignore_error then
      notification.error(unable)
    end

    return failed_result(cmd, unable)
  end

  local env = M.env()
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end

  local p = process.new {
    cmd = cmd,
    cwd = cwd,
    env = env,
    input = opts.input,
    on_error = function(res)
      if opts.on_error then
        return opts.on_error(res)
      end

      return not opts.ignore_error
    end,
    pty = false,
    suppress_console = not not (opts.hidden or opts.long),
    user_command = opts.user_command == true,
  }

  local result = runner.call(p, {
    await = opts.await,
    long = opts.long,
    hidden = opts.hidden,
    trim = opts.trim,
    remove_ansi = false,
  }) --[[@as SvenCliResult]]

  if not opts.raw then
    drop_trailing_empty(result.stdout)
    drop_trailing_empty(result.stderr)
  end

  -- A failure the user was told about must be inspectable in the command history
  if result.code ~= 0 and not opts.ignore_error then
    result.hidden = false
  end

  return result
end

---Picks the options that are forwarded from a library function to `run`
---@param opts table|nil Options given to a library function
---@param defaults SvenCliOpts|nil
---@return SvenCliOpts
function M.opts(opts, defaults)
  local result = vim.deepcopy(defaults or {})
  for _, key in ipairs { "hidden", "await", "ignore_error", "cwd", "env", "long", "on_error", "user_command" } do
    if opts and opts[key] ~= nil then
      result[key] = opts[key]
    end
  end

  return result
end

return M
