local logger = require("sven.logger")

---Runs a `Process` and records its result in the command history.
---
---svn is always invoked with `--non-interactive`, so unlike Neogit's runner there is no PTY
---and no prompt handling here: a command either completes or fails, it never waits for input.
local M = {
  ---@type ProcessResult[] every finished command, oldest first. Rendered by the command history buffer.
  history = {},
}

---@param job ProcessResult
local function store_process_result(job)
  table.insert(M.history, job)

  do
    if job.code > 0 then
      logger.trace(
        string.format(
          "[RUNNER] Execution of '%s' failed with code %d after %d ms",
          job.cmd,
          job.code,
          job.time
        )
      )

      for _, line in ipairs(job.stderr) do
        if line ~= "" then
          logger.trace(string.format("[RUNNER] [STDERR] %s", line))
        end
      end
    else
      logger.trace(string.format("[RUNNER] Execution of '%s' succeeded in %d ms", job.cmd, job.time))
    end
  end
end

---@class RunnerOpts
---@field await? boolean block Neovim until the process exits, even inside an async context
---@field long? boolean the command is expected to run for a long time: do not pop up the console
---@field hidden? boolean hide the command from the command history buffer
---@field trim? boolean remove blank lines from the output
---@field remove_ansi? boolean remove ansi escape codes (and carriage returns) from the output
---@field callback? fun() called once the command finished

---Runs the process.
---
---Inside a `sven.lib.async` context the calling coroutine is suspended until the process exits,
---so Neovim stays responsive. Outside of one (or with `opts.await`) Neovim blocks until it exits.
---@param process Process
---@param opts RunnerOpts
---@return ProcessResult
function M.call(process, opts)
  logger.trace(string.format("[RUNNER]: Executing %q", table.concat(process.cmd, " ")))

  local function run(proc)
    local result
    local function run_async()
      result = proc:spawn_async()
      if opts.long then
        proc:stop_timer()
      end
    end

    local function run_await()
      if not proc:spawn() then
        error("Failed to run command")
        return nil
      end
      result = proc:wait()
    end

    if opts.await then
      logger.trace("Running command await: " .. vim.inspect(proc.cmd))
      run_await()
    else
      logger.trace("Running command async: " .. vim.inspect(proc.cmd))
      local ok, _ = pcall(run_async)
      if not ok then
        logger.trace("Running command async failed - awaiting instead")
        run_await()
      end
    end

    return result
  end

  local result = run(process)
  assert(result, "Command did not complete")
  store_process_result(result)

  result.hidden = opts.hidden

  if opts.trim then
    result:trim()
  end

  if opts.remove_ansi then
    result:remove_ansi()
  end

  if opts.callback then
    opts.callback()
  end

  return result
end

return M
