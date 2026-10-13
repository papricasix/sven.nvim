local M = {}

M.project_dir = vim.fn.getcwd()

---Runs a system command and errors if it fails
---@param cmd string[] Command to be ran
---@param opts { cwd: string?, ignore_err: boolean?, env: table<string, string>? }|nil
---@return string stdout The output of the command
---@return number code Its exit code
function M.system(cmd, opts)
  opts = opts or {}

  local result = vim.system(cmd, { text = true, cwd = opts.cwd, env = opts.env }):wait()
  if result.code > 0 and not opts.ignore_err then
    error(
      "Command failed: ↓\n"
        .. table.concat(cmd, " ")
        .. "\nOutput from command: ↓\n"
        .. (result.stdout or "")
        .. "\n"
        .. (result.stderr or "")
    )
  end

  return result.stdout or "", result.code
end

---Creates a temporary directory
---@return string path Absolute path with symlinks resolved (on macOS the temp dir is behind one)
function M.create_temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  return vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
end

---@param path string
---@return string content
function M.read_file(path)
  local fd = assert(io.open(path, "rb"), "Unable to read " .. path)
  local content = fd:read("*a")
  fd:close()

  return content
end

---Writes a file, creating its directory if needed
---@param path string
---@param content string
function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local fd = assert(io.open(path, "wb"), "Unable to write " .. path)
  fd:write(content)
  fd:close()
end

---Blocks until `condition` holds
---@param condition fun(): boolean
---@param timeout number|nil Milliseconds, defaults to 5000
---@return boolean ok Whether the condition was met in time
function M.wait_for(condition, timeout)
  return vim.wait(timeout or 5000, condition, 10)
end

---Gets the editor back to one plain window in the project directory: closes all other windows
---and tabs, wipes the buffers of sven and drops the local directory of the remaining window
---(a status buffer makes its window local to the working copy, which a spec then removes).
function M.reset_editor()
  -- Status buffers remember their state, close them the regular way first
  local ok, status = pcall(require, "sven.buffers.status")
  if ok and status.instance then
    for _, dir in ipairs { vim.uv.cwd() or "", vim.fn.getcwd(-1, -1) } do
      local instance = dir ~= "" and status.instance(dir) or nil
      if instance then
        pcall(instance.close, instance)
      end
    end
  end

  vim.cmd("silent! stopinsert")
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("cd " .. vim.fn.fnameescape(M.project_dir))

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = buf })
    if filetype:match("^Sven") or filetype == "gitcommit" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Let scheduled window closes happen
  vim.wait(20, function()
    return false
  end)
end

---Collects the messages sent through `vim.notify` while `fn` runs.
---Notifications of sven are scheduled, so pending ones are flushed before returning.
---@param fn fun()
---@return { message: string, level: integer }[]
function M.capture_notifications(fn)
  local notifications = {}
  local original = vim.notify

  vim.notify = function(message, level)
    table.insert(notifications, { message = message, level = level })
  end

  local ok, err = pcall(fn)

  -- Let scheduled notifications run
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end, 5)

  vim.notify = original

  if not ok then
    error(err, 0)
  end

  return notifications
end

return M
