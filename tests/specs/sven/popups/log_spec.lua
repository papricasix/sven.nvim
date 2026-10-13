local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@param buf integer|nil
---@return string[] The lines of a buffer, without trailing whitespace
local function lines(buf)
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false))
end

---@return string[] The lines that are not hidden in a closed fold
local function visible_lines()
  local result = {}
  local all = lines()

  local line = 1
  while line <= #all do
    table.insert(result, all[line])

    local fold_end = vim.fn.foldclosedend(line)
    line = (fold_end == -1 and line or fold_end) + 1
  end

  return result
end

describe("popups.log", function()
  local wc
  local svn
  local LogView
  local input
  local original_get_user_input

  ---What the user types when asked for input
  local typed

  ---@param env table|nil
  ---@return PopupData
  local function open_popup(env)
    wc:refresh()
    local popup = require("sven.popups.log").create(env)
    assert.are.same("SvenPopup", vim.bo.filetype)

    return popup
  end

  ---@param popup PopupData
  ---@param cli string
  ---@return table
  local function argument(popup, cli)
    for _, arg in ipairs(popup.state.args) do
      if arg.cli == cli then
        return arg
      end
    end

    error("No argument " .. cli)
  end

  ---Waits for the log view an action opens
  ---@return SvenLogView
  local function wait_for_log()
    assert.is_true(
      util.wait_for(function()
        return vim.bo.filetype == "SvenLogView"
      end, 10000),
      "The log view did not open"
    )

    return LogView.instance
  end

  ---@return string header What the log view says it is the log of
  local function header()
    local buf = vim.api.nvim_win_get_buf(LogView.instance.buffer.header_win_handle)
    return vim.trim(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
  end

  ---@return string cmd The last `svn log` that was run
  local function last_log_command()
    for index = #svn.cli.history, 1, -1 do
      local cmd = svn.cli.history[index].cmd
      if cmd:find(" log ", 1, true) then
        return cmd
      end
    end

    return ""
  end

  before_each(function()
    wc = harness.create()
    svn = require("sven.lib.svn")
    LogView = require("sven.buffers.log_view")

    -- r3 and r4 change files of the trunk, r5 happens next to it
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:commit("Change a")
    wc:replace("b.txt", "hello", "bye")
    wc:commit("Change b")
    harness.svn({ "mkdir", "-q", "-m", "Make a branch directory", wc.repo_url .. "/branches/x" }, wc.path)
    wc:update()

    input = require("sven.lib.input")
    original_get_user_input = input.get_user_input
    typed = nil
    input.get_user_input = function()
      return typed
    end
  end)

  after_each(function()
    input.get_user_input = original_get_user_input

    local popup = require("sven.lib.popup")
    util.wait_for(function()
      return popup.__lock.permits > 0
    end, 10000)
    if popup.is_open() then
      popup.instance:close()
    end

    util.reset_editor()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.startswith(vim.api.nvim_buf_get_name(buf), wc.path) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    harness.cleanup()
  end)

  describe("the popup", function()
    it("offers the logs and their options", function()
      open_popup()

      assert.are.same({
        "Revision Limiting",
        "-l Limit number of revisions (--limit=256)",
        "-s Search author, date, message and changed paths (--search=)",
        "-r Revision or range (42, 100:50, {2026-01-01}:HEAD) (--revision=)",
        "",
        "History",
        "-c Stop at copies: stay on this branch (--stop-on-copy)",
        "-g Show the revisions that were merged (--use-merge-history)",
        "",
        "Formatting",
        "-v Show changed paths (--verbose)",
        "",
        "Log",
        "l working copy",
        "r repository",
        "p path or URL",
      }, lines())
    end)

    it("offers the log of the file it was opened on", function()
      open_popup { paths = { "src/main.c" } }

      assert.are.same(
        { "Log", "l working copy", "f main.c", "r repository", "p path or URL" },
        vim.list_slice(lines(), 13)
      )
    end)

    it("offers the log of the file of the buffer it was opened from", function()
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("a.txt")))
      open_popup {}

      assert.are.same("f a.txt", lines()[15])
    end)

    it("is what :Sven log opens", function()
      vim.cmd("Sven log cwd=" .. wc.path)

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "SvenPopup"
      end))
      assert.are.same("l working copy", lines()[14])
    end)
  end)

  describe("its logs", function()
    it("shows the history of the working copy", function()
      open_popup()
      feed("l")
      local view = wait_for_log()

      assert.are.same("Revisions in ^/trunk", header())
      assert.are.same({
        "",
        "r4  Change b",
        "r3  Change a",
        "r2  Add the initial files",
        "r1  Create the layout",
      }, visible_lines())
      assert.is_nil(view.files)
      assert.is_false(view.has_more)
      assert.are.same(wc.path, view.root)

      -- Changed paths were asked for
      assert.are.same("   M /trunk/b.txt", lines()[8])
    end)

    it("shows the history of a file", function()
      open_popup { paths = { "a.txt" } }
      feed("f")
      local view = wait_for_log()

      assert.are.same("Revisions of a.txt", header())
      assert.are.same({ "", "r3  Change a", "r2  Add the initial files" }, visible_lines())
      assert.are.same({ "a.txt" }, view.files)
    end)

    it("shows the history of the file of the buffer it was opened from", function()
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("b.txt")))
      open_popup {}
      feed("f")
      wait_for_log()

      assert.are.same("Revisions of b.txt", header())
      assert.are.same({ "", "r4  Change b", "r2  Add the initial files" }, visible_lines())
    end)

    it("shows the history of the whole repository", function()
      open_popup()
      feed("r")
      wait_for_log()

      assert.are.same("Revisions in ^/", header())
      assert.are.same({
        "",
        "r5  Make a branch directory",
        "r4  Change b",
        "r3  Change a",
        "r2  Add the initial files",
        "r1  Create the layout",
      }, visible_lines())
    end)

    it("shows the history of a path that is asked for", function()
      typed = "src/main.c"

      open_popup()
      feed("p")
      local view = wait_for_log()

      assert.are.same("Revisions of src/main.c", header())
      assert.are.same({ "", "r2  Add the initial files" }, visible_lines())
      assert.are.same({ "src/main.c" }, view.files)
    end)

    it("shows the history of a URL that is asked for", function()
      typed = "^/branches"

      open_popup()
      feed("p")
      local view = wait_for_log()

      assert.are.same("Revisions of ^/branches", header())
      assert.are.same({ "", "r5  Make a branch directory", "r1  Create the layout" }, visible_lines())
      assert.is_nil(view.files)
    end)

    it("does nothing when no path is given", function()
      typed = nil

      open_popup()
      feed("p")

      local popup = require("sven.lib.popup")
      util.wait_for(function()
        return popup.__lock.permits > 0
      end)
      assert.are_not.same("SvenLogView", vim.bo.filetype)
    end)

    it("opens no log view when svn fails", function()
      typed = "^/no/such/path"

      local notifications = util.capture_notifications(function()
        open_popup()
        feed("p")

        local popup = require("sven.lib.popup")
        util.wait_for(function()
          return popup.__lock.permits > 0 and not popup.is_open()
        end)
      end)

      assert.are_not.same("SvenLogView", vim.bo.filetype)
      assert.is_true(#notifications >= 1)
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    end)
  end)

  describe("its options", function()
    it("limits the number of revisions", function()
      local popup = open_popup()
      argument(popup, "limit").value = "2"
      feed("l")
      local view = wait_for_log()

      assert.are.same({ "", "r4  Change b", "r3  Change a", "Type + to show more history" }, visible_lines())
      assert.is_true(view.has_more)
    end)

    it("shows everything without a limit", function()
      local popup = open_popup()
      argument(popup, "limit").value = ""
      feed("l")
      local view = wait_for_log()

      assert.are.same(5, #visible_lines())
      assert.is_false(view.has_more)
      assert.is_nil(last_log_command():find(" -l ", 1, true))
    end)

    it("searches", function()
      local popup = open_popup()
      popup:set_option(argument(popup, "search"), "Change a")
      feed("l")
      wait_for_log()

      assert.are.same({ "", "r3  Change a", "Type + to show more history" }, visible_lines())
    end)

    it("takes a revision range", function()
      local popup = open_popup()
      popup:set_option(argument(popup, "revision"), "r2:r3")
      feed("l")
      wait_for_log()

      assert.are.same({ "", "r2  Add the initial files", "r3  Change a" }, visible_lines())
    end)

    it("takes a single revision", function()
      local popup = open_popup()
      popup:set_option(argument(popup, "revision"), "3")
      feed("l")
      local view = wait_for_log()

      assert.are.same({ "", "r3  Change a" }, visible_lines())
      assert.is_false(view.has_more)
    end)

    it("passes its switches on to svn", function()
      local popup = open_popup()
      popup:toggle_switch(argument(popup, "stop-on-copy"))
      popup:toggle_switch(argument(popup, "use-merge-history"))
      feed("l")
      wait_for_log()

      local cmd = last_log_command()
      assert.is_truthy(cmd:find("--stop-on-copy", 1, true))
      assert.is_truthy(cmd:find("--use-merge-history", 1, true))
      assert.is_truthy(cmd:find(" -v ", 1, true))
      assert.is_truthy(cmd:find("-l 256", 1, true))
    end)

    it("leaves the changed paths out when told to", function()
      local popup = open_popup()
      popup:toggle_switch(argument(popup, "verbose"))
      feed("l")
      wait_for_log()

      assert.is_nil(last_log_command():find(" -v ", 1, true))
      -- Folded away below the newest row: author, date and message, but no paths
      assert.are.same("r3  Change a", lines()[7])
    end)
  end)

  describe("actions", function()
    local actions

    before_each(function()
      actions = require("sven.popups.log.actions")
    end)

    it("can be bound to keys", function()
      require("sven").action("log", "log_repository", { "--limit=3" })()
      local view = wait_for_log()

      assert.are.same(3, #view.entries)
      assert.are.same(5, view.entries[1].revision)
      assert.is_true(view.has_more)
    end)

    it("turns the arguments of the popup into a query", function()
      assert.are.same({ args = {} }, actions.parse_arguments {})

      assert.are.same(
        {
          limit = 25,
          revision = "100:50",
          search = { "fix" },
          verbose = true,
          stop_on_copy = true,
          args = { "--use-merge-history" },
        },
        actions.parse_arguments {
          "--limit=25",
          "--revision=r100:r50",
          "--search=fix",
          "--verbose",
          "--stop-on-copy",
          "--use-merge-history",
        }
      )

      assert.are.same(
        "{2026-01-01}:HEAD",
        actions.parse_arguments({ "--revision={2026-01-01}:HEAD" }).revision
      )
      assert.is_nil(actions.parse_arguments({ "--limit=0" }).limit)
      assert.is_nil(actions.parse_arguments({ "--search=" }).search)
      assert.is_nil(actions.parse_arguments({ "--revision=" }).revision)
    end)

    it("splits revision ranges", function()
      assert.are.same({ "100", "50" }, { actions.split_range("100:50") })
      assert.are.same({ "42" }, { actions.split_range("42") })
      assert.are.same({ "{2026-01-01T12:00}", "HEAD" }, { actions.split_range("{2026-01-01T12:00}:HEAD") })
      assert.are.same({ "HEAD", "{2026-01-01T12:00}" }, { actions.split_range("HEAD:{2026-01-01T12:00}") })
    end)

    it("knows the range of the next page", function()
      ---@param ... integer Revisions
      local function entries(...)
        return vim.tbl_map(function(revision)
          return { revision = revision }
        end, { ... })
      end

      -- Everything, newest first
      assert.are.same("7:1", actions.next_range(nil, entries(10, 9, 8)))
      assert.is_nil(actions.next_range(nil, entries(3, 2, 1)))
      assert.is_nil(actions.next_range(nil, {}))

      -- A range that runs down
      assert.are.same("7:5", actions.next_range("10:5", entries(10, 9, 8)))
      assert.is_nil(actions.next_range("10:8", entries(10, 9, 8)))
      assert.are.same("7:2", actions.next_range("HEAD:2", entries(10, 9, 8)))

      -- A range that runs up
      assert.are.same("8:10", actions.next_range("5:10", entries(5, 6, 7)))
      assert.is_nil(actions.next_range("5:7", entries(5, 6, 7)))

      -- A single revision
      assert.is_nil(actions.next_range("7", entries(7)))
    end)

    it("knows when a page cannot simply be continued", function()
      assert.is_false(actions.needs_refetch {})
      assert.is_false(actions.needs_refetch { revision = "10:5" })
      assert.is_false(actions.needs_refetch { revision = "HEAD:5" })
      assert.is_false(actions.needs_refetch { revision = "7" })

      assert.is_true(actions.needs_refetch { search = { "fix" } })
      assert.is_true(actions.needs_refetch { revision = "HEAD:{2026-01-01}" })
      assert.is_true(actions.needs_refetch { revision = "5:HEAD" })
    end)
  end)
end)
