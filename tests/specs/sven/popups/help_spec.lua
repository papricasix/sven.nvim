local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local t = require("tests.specs.sven.buffers.status_helpers")

describe("popups.help", function()
  local wc

  ---@return string The text of the popup that is open
  local function popup_text()
    assert.are.same("SvenPopup", vim.bo.filetype)
    return table.concat(t.lines(), "\n")
  end

  before_each(function()
    wc = harness.create()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
  end)

  after_each(function()
    t.close()
    t.unstub_modules()
    harness.cleanup()
  end)

  it("is registered and opens from the status buffer with ?", function()
    assert.is_function(require("sven.popups").load("help").create)

    t.open(wc)
    t.feed("?")

    assert.are.same("SvenPopup", vim.bo.filetype)
    assert.are.same("SvenHelpPopup", require("sven.lib.popup").instance.state.name)
  end)

  it("lists the popups of sven with their keys", function()
    t.open(wc)
    t.feed("?")
    local text = popup_text()

    assert.is_truthy(text:match("Commands%s+Applying changes%s+Essential commands"))
    assert.is_truthy(text:match("c Commit"))
    assert.is_truthy(text:match("d Diff"))
    assert.is_truthy(text:match("l Log"))
    assert.is_truthy(text:match("F Update"))
    assert.is_truthy(text:match("r Resolve"))
    assert.is_truthy(text:match("%$ History"))
    assert.is_truthy(text:match("Q Command"))

    -- Every popup of the registry is listed, the help popup itself aside
    for _, name in ipairs(require("sven.popups").names) do
      if name ~= "help" then
        local title = name:sub(1, 1):upper() .. name:sub(2)
        assert.is_truthy(text:match("%S+ " .. title), title)
      end
    end

    -- Nothing of git that Subversion does not have
    for _, absent in ipairs { "Push", "Pull", "Rebase", "Stash", "Branch", "Fetch", "Merge", "Untrack" } do
      assert.is_falsy(text:match(absent), absent)
    end
  end)

  it("lists the commands that apply changes and the essential ones", function()
    t.open(wc)
    t.feed("?")
    local text = popup_text()

    assert.is_truthy(text:match("s Stage"))
    assert.is_truthy(text:match("S Stage changes"))
    assert.is_truthy(text:match("<c%-s> Stage all"))
    assert.is_truthy(text:match("u Unstage"))
    assert.is_truthy(text:match("U Unstage all"))
    assert.is_truthy(text:match("x Discard"))

    assert.is_truthy(text:match("<c%-r> Refresh"))
    assert.is_truthy(text:match("<cr> Go to file"))
    assert.is_truthy(text:match("<tab> Toggle"))
    assert.is_truthy(text:match("B Blame"))
  end)

  it("shows the keys that are configured", function()
    harness.setup {
      mappings = {
        status = { ["s"] = false, ["gs"] = "Stage", ["x"] = false },
        popup = { ["c"] = false, ["C"] = "CommitPopup" },
      },
    }

    require("sven.popups.help").create {}
    local text = popup_text()

    assert.is_truthy(text:match("gs Stage"))
    assert.is_truthy(text:match("C Commit"))
    -- Unmapped commands are listed without a key
    assert.is_truthy(text:match("_ Discard"))
    assert.is_falsy(text:match("x Discard"))
  end)

  it("opens the popup whose key is pressed, with what the cursor was on", function()
    local created = {}
    for _, name in ipairs { "commit", "log", "diff" } do
      t.stub_module("sven.popups." .. name, {
        create = function(env)
          table.insert(created, { name = name, env = env })
        end,
      })
    end

    t.open(wc)
    t.go("modified     a.txt")

    for _, key in ipairs { "c", "l", "d" } do
      t.feed("?")
      assert.are.same("SvenPopup", vim.bo.filetype)
      t.feed(key)
      t.wait(function()
        return vim.bo.filetype == "SvenStatus"
      end, "the help popup to close")
    end

    assert.are.same(
      { "commit", "log", "diff" },
      vim.tbl_map(function(popup)
        return popup.name
      end, created)
    )

    for _, popup in ipairs(created) do
      assert.are.same("a.txt", popup.env.item.name)
      assert.are.same({ name = "changes" }, popup.env.section)
      assert.are.same({ "a.txt" }, popup.env.paths)
    end
  end)

  it("opens the popups of the status buffer itself", function()
    t.open(wc)
    t.go("modified     a.txt")

    t.feed("?")
    t.feed("F")

    t.wait(function()
      local popup = require("sven.lib.popup")
      return popup.is_open() and popup.instance.state.name == "SvenUpdatePopup"
    end, "the update popup to open")
    assert.is_truthy(popup_text():match("f a%.txt"))
  end)

  it("opens the command history", function()
    t.open(wc)
    require("sven.lib.svn").cli.run { "info", "--show-item", "revision" }

    t.feed("?")
    t.feed("$")

    t.wait(function()
      return vim.bo.filetype == "SvenCommandHistory"
    end, "the command history to open")
  end)

  it("refreshes the status buffer", function()
    t.open(wc)
    wc:write("new.txt", "new\n")

    t.feed("?")
    t.feed("<c-r>")

    t.wait(function()
      return vim.bo.filetype == "SvenStatus" and t.has("Unversioned files (1)")
    end, "the status buffer to be refreshed")
  end)

  it("can be opened without a status buffer", function()
    wc:use()

    local notifications = util.capture_notifications(function()
      vim.cmd("Sven help cwd=" .. wc.path)
      t.wait(function()
        return vim.bo.filetype == "SvenPopup"
      end, "the popup to open")
    end)

    assert.are.same({}, notifications)
    assert.is_truthy(popup_text():match("Essential commands"))
  end)
end)
