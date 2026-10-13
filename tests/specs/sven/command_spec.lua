local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

describe(":Sven", function()
  local sven = require("sven")
  local popups = require("sven.popups")
  local wc

  -- A popup that is in the registry but has not been written
  local UNWRITTEN = "ghost"

  ---Makes `require("sven.popups.<name>")` return a module, whether that popup exists or not
  ---@param name string
  ---@param module table
  local function implement(name, module)
    package.loaded["sven.popups." .. name] = nil
    package.preload["sven.popups." .. name] = function()
      return module
    end
  end

  before_each(function()
    wc = harness.create()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
  end)

  after_each(function()
    harness.settle()

    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end

    util.reset_editor()
    harness.cleanup()

    if popups.names[#popups.names] == UNWRITTEN then
      table.remove(popups.names)
    end

    for _, name in ipairs(popups.names) do
      package.preload["sven.popups." .. name] = nil
      package.loaded["sven.popups." .. name] = nil
    end
  end)

  it("exists, with completion", function()
    local command = vim.api.nvim_get_commands({})["Sven"]

    assert.is_not_nil(command)
    assert.are.same("*", command.nargs)
    assert.is_not_nil(vim.api.nvim_get_commands({})["SvenResetState"])
  end)

  describe("completion", function()
    it("offers the options and the popups", function()
      assert.are.same(
        { "kind=", "cwd=", "help", "commit", "log", "diff", "update", "resolve" },
        sven.complete("")
      )
    end)

    it("narrows down by what was typed", function()
      assert.are.same({ "commit" }, sven.complete("co"))
      assert.are.same({ "cwd=", "commit" }, sven.complete("c"))
      assert.are.same({}, sven.complete("push"))
    end)

    it("offers the window kinds", function()
      local kinds = sven.complete("kind=")

      assert.is_true(vim.tbl_contains(kinds, "kind=tab"))
      assert.is_true(vim.tbl_contains(kinds, "kind=split"))
      assert.is_true(vim.tbl_contains(kinds, "kind=vsplit"))
      assert.is_true(vim.tbl_contains(kinds, "kind=floating"))
    end)

    it("offers the working directory", function()
      assert.are.same({ "cwd=" .. vim.uv.cwd() }, sven.complete("cwd="))
    end)

    it("is what the command completes with", function()
      assert.are.same({ "diff" }, vim.fn.getcompletion("Sven di", "cmdline"))
    end)
  end)

  it("parses its arguments like :Neogit does", function()
    local parse = require("sven.lib.util").parse_command_args

    assert.are.same({}, parse {})
    assert.are.same({ kind = "split" }, parse { "kind=split" })
    assert.are.same(
      { "commit", kind = "split", cwd = "/tmp/wc" },
      parse { "commit", "kind=split", "cwd=/tmp/wc" }
    )
  end)

  it("opens the status buffer of a working copy", function()
    vim.cmd("Sven cwd=" .. wc.path .. " kind=split")

    assert.are.same("SvenStatus", vim.bo.filetype)
    assert.is_true(require("sven.buffers.status").instance(wc.path) ~= nil)
    assert.are.same(wc.path, require("sven.lib.svn").repo.root)
    -- The buffer lives in the directory it was opened for
    assert.are.same(wc.path, vim.fn.getcwd(0))
    assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("shows the state of the working copy in the status buffer", function()
    vim.cmd("Sven cwd=" .. wc.path .. " kind=split")

    local function lines()
      return vim.tbl_map(function(line)
        return (line:gsub("%s+$", ""))
      end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end

    assert.is_true(util.wait_for(function()
      return vim.tbl_contains(lines(), "modified     a.txt")
    end))
    assert.is_truthy(table.concat(lines(), "\n"):match("\nHead:%s+r2 %^/trunk"))
    assert.is_true(vim.tbl_contains(lines(), "Changes (1)"))
    assert.is_true(require("sven.buffers.status").is_open())
  end)

  it("focuses the status buffer that is open already", function()
    vim.cmd("Sven cwd=" .. wc.path .. " kind=split")
    vim.cmd("wincmd p")
    assert.are_not.same("SvenStatus", vim.bo.filetype)

    vim.cmd("Sven cwd=" .. wc.path .. " kind=split")

    assert.are.same("SvenStatus", vim.bo.filetype)
    assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("opens in the kind it is told to", function()
    vim.cmd("Sven cwd=" .. wc.path .. " kind=tab")

    assert.are.same("SvenStatus", vim.bo.filetype)
    assert.are.same(2, #vim.api.nvim_list_tabpages())
  end)

  it("opens the working copy of the current directory by default", function()
    vim.cmd("cd " .. vim.fn.fnameescape(wc:abs("src")))

    vim.cmd("Sven kind=split")

    assert.are.same("SvenStatus", vim.bo.filetype)
    assert.are.same(wc.path, require("sven.lib.svn").repo.root)
  end)

  it("can be called from lua", function()
    sven.open { cwd = wc.path, kind = "split" }

    assert.are.same("SvenStatus", vim.bo.filetype)
  end)

  it("refuses directories that are not in a working copy", function()
    local dir = util.create_temp_dir()

    local notifications = util.capture_notifications(function()
      vim.cmd("Sven cwd=" .. dir)
    end)

    assert.are.same(1, #notifications)
    assert.is_truthy(notifications[1].message:match("is not inside a Subversion working copy"))
    assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    assert.are_not.same("SvenStatus", vim.bo.filetype)

    vim.fn.delete(dir, "rf")
  end)

  it("opens a popup by name, once the state is known", function()
    local changes_when_created = nil
    local created_with = nil
    implement("commit", {
      create = function(env)
        changes_when_created = #require("sven.lib.svn").repo.state.changes.items
        created_with = env
      end,
    })

    vim.cmd("Sven commit cwd=" .. wc.path)

    assert.is_true(util.wait_for(function()
      return changes_when_created ~= nil
    end))
    assert.are.same(1, changes_when_created)
    assert.are.same({}, created_with)
    assert.are_not.same("SvenStatus", vim.bo.filetype)
  end)

  it("opens the popups that act on the working copy by name", function()
    vim.cmd("Sven help cwd=" .. wc.path)

    assert.is_true(util.wait_for(function()
      return vim.bo.filetype == "SvenPopup"
    end))
    assert.are.same("SvenHelpPopup", require("sven.lib.popup").instance.state.name)

    vim.cmd("Sven update cwd=" .. wc.path)

    assert.is_true(util.wait_for(function()
      return require("sven.lib.popup").instance.state.name == "SvenUpdatePopup"
    end))
  end)

  it("says so when a popup is not implemented yet", function()
    table.insert(popups.names, UNWRITTEN)

    local notifications = util.capture_notifications(function()
      vim.cmd(("Sven %s cwd=%s"):format(UNWRITTEN, wc.path))
      harness.settle()
    end)

    assert.are.same(1, #notifications)
    assert.are.same("The ghost popup is not implemented yet", notifications[1].message)
  end)

  it("rejects popups it does not know", function()
    local notifications = util.capture_notifications(function()
      vim.cmd("Sven push cwd=" .. wc.path)
    end)

    assert.are.same(1, #notifications)
    assert.is_truthy(notifications[1].message:match("Invalid popup"))
  end)

  describe("action", function()
    it("builds a function that runs a popup action with arguments", function()
      local arguments = nil
      package.loaded["sven.popups.log.actions"] = nil
      package.preload["sven.popups.log.actions"] = function()
        return {
          log_current = function(popup)
            arguments = popup:get_arguments()
          end,
        }
      end

      sven.action("log", "log_current", { "--limit=5" })()

      assert.is_true(util.wait_for(function()
        return arguments ~= nil
      end))
      assert.are.same({ "--limit=5" }, arguments)

      package.preload["sven.popups.log.actions"] = nil
      package.loaded["sven.popups.log.actions"] = nil
    end)

    it("reports actions that do not exist", function()
      local notifications = util.capture_notifications(function()
        sven.action("update", "run")()
        harness.settle()
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("Invalid action run for update popup"))
      assert.is_truthy(notifications[1].message:match("Valid actions are: .*head"))
    end)

    it("reports popups that have no actions", function()
      local notifications = util.capture_notifications(function()
        sven.action(UNWRITTEN, "run")()
        harness.settle()
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("ghost popup has no actions"))
    end)
  end)
end)
