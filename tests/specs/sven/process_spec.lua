local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local a = require("sven.lib.async")

---The console and the spinner, which watch over svn commands that take a while
describe("process", function()
  local svn, dir, slow

  ---Runs the slow "svn" in the background
  ---@param args string[]
  ---@param opts SvenCliOpts|nil
  ---@return fun(): SvenCliResult|nil result Yields the result once the command finished
  local function run_in_background(args, opts)
    local result
    a.void(function()
      result = svn.cli.run(args, vim.tbl_extend("force", { cwd = dir }, opts or {}))
    end)()

    return function()
      return result
    end
  end

  ---@return integer|nil window The window showing the console
  local function console_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "SvenConsole" then
        return win
      end
    end
  end

  ---@return string
  local function console_text()
    local win = console_window()
    if not win then
      return ""
    end

    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
  end

  before_each(function()
    dir = util.create_temp_dir()

    -- Stands in for an svn that talks to a slow server: prints, waits, prints, exits with $1
    slow = dir .. "/slow-svn"
    util.write_file(
      slow,
      table.concat({
        "#!/bin/sh",
        'echo "first line"',
        "sleep 0.6",
        'echo "second line"',
        'echo "an error" >&2',
        'exit "$2"',
        "",
      }, "\n")
    )
    vim.uv.fs_chmod(slow, 493) -- 0755

    harness.setup { svn_executable = slow, console_timeout = 100 }
    svn = require("sven.lib.svn")
  end)

  after_each(function()
    util.wait_for(function()
      return console_window() == nil
    end, 2000)

    util.reset_editor()
    vim.fn.delete(dir, "rf")
  end)

  it("shows the console when a command takes long, and closes it on success", function()
    local result = run_in_background { "0" }

    assert.is_true(util.wait_for(function()
      return console_window() ~= nil
    end, 2000))
    assert.is_nil(result())

    -- The console is a terminal, which renders what it is sent a moment later
    assert.is_true(util.wait_for(function()
      return console_text():match("first line") ~= nil
    end, 2000))
    -- The command line comes first. The terminal wraps it, the path of the executable is long.
    local unwrapped = console_text():gsub("\n", "")
    assert.is_truthy(unwrapped:match("^> .*slow%-svn 0"))
    assert.is_falsy(unwrapped:match("non%-interactive"))

    assert.is_true(util.wait_for(function()
      return result() ~= nil
    end, 3000))
    assert.are.same(0, result().code)
    assert.are.same({ "first line", "second line" }, result().stdout)
    assert.are.same({ "an error" }, result().stderr)

    assert.is_true(util.wait_for(function()
      return console_window() == nil
    end, 2000))
  end)

  it("leaves the console open when the command failed, and notifies", function()
    local result
    local notifications = util.capture_notifications(function()
      result = run_in_background { "3" }

      util.wait_for(function()
        return result() ~= nil
      end, 3000)
    end)

    assert.are.same(3, result().code)
    assert.is_not_nil(console_window())
    assert.is_true(util.wait_for(function()
      return console_text():match("Process exited with code: 3") ~= nil
    end, 2000))

    assert.are.same(1, #notifications)
    assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].message:match("> an error"))

    -- Closed by hand
    vim.api.nvim_win_close(console_window(), true)
  end)

  it("does not show the console for hidden commands", function()
    local result = run_in_background({ "0" }, { hidden = true })

    util.wait_for(function()
      return result() ~= nil
    end, 3000)

    assert.are.same(0, result().code)
    assert.is_nil(console_window())
  end)

  it("does not show the console for commands that are expected to take long", function()
    local result = run_in_background({ "0" }, { long = true })

    util.wait_for(function()
      return result() ~= nil
    end, 3000)

    assert.are.same(0, result().code)
    assert.is_nil(console_window())
  end)

  it("warns instead of showing the console when that is turned off", function()
    harness.setup { svn_executable = slow, console_timeout = 100, auto_show_console = false }

    local result
    local notifications = util.capture_notifications(function()
      result = run_in_background { "0" }

      util.wait_for(function()
        return result() ~= nil
      end, 3000)
    end)

    assert.is_nil(console_window())
    assert.are.same(1, #notifications)
    assert.are.same(vim.log.levels.WARN, notifications[1].level)
    assert.is_truthy(notifications[1].message:match("running for more than"))
  end)

  it("only shows the console for failures when asked to", function()
    harness.setup { svn_executable = slow, console_timeout = 100, auto_show_console_on = "error" }

    local result = run_in_background { "0" }
    util.wait_for(function()
      return result() ~= nil
    end, 3000)
    assert.is_nil(console_window())

    util.capture_notifications(function()
      result = run_in_background { "1" }
      util.wait_for(function()
        return result() ~= nil
      end, 3000)
    end)
    assert.is_not_nil(console_window())

    vim.api.nvim_win_close(console_window(), true)
  end)

  it("runs the spinner while a command is running", function()
    harness.setup { svn_executable = slow, console_timeout = 5000, process_spinner = true }
    local Spinner = require("sven.spinner")

    local started, stopped = 0, 0
    local start, stop = Spinner.start, Spinner.stop
    Spinner.start = function(self, ...)
      started = started + 1
      return start(self, ...)
    end
    Spinner.stop = function(self, ...)
      stopped = stopped + 1
      return stop(self, ...)
    end

    local result = run_in_background { "0" }
    assert.are.same(1, started)
    assert.are.same(0, stopped)

    util.wait_for(function()
      return result() ~= nil
    end, 3000)
    assert.are.same(1, stopped)

    Spinner.start, Spinner.stop = start, stop
  end)

  it("can be stopped", function()
    local Process = require("sven.process")

    local process = Process.new {
      cmd = { slow, "--non-interactive", "0" },
      cwd = dir,
      on_error = function()
        return false
      end,
      suppress_console = true,
      user_command = false,
    }

    local result
    process:spawn(function(res)
      result = res
    end)

    -- Let it print its first line, then stop it while it sleeps
    vim.wait(250, function()
      return false
    end)
    assert.is_nil(result)
    process:stop()

    assert.is_true(util.wait_for(function()
      return result ~= nil
    end, 2000))
    assert.is_true(result.code ~= 0)
    assert.are.same({ "first line", "" }, result.stdout)
  end)
end)
