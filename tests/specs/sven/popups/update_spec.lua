local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local t = require("tests.specs.sven.buffers.status_helpers")

describe("popups.update", function()
  local wc, other
  local restore_input

  ---Answers the prompt for a revision, and records how it was asked
  ---@param answer string|nil
  ---@return { prompt: string, default: string|nil }[]
  local function answer_revision(answer)
    local input = require("sven.lib.input")
    local original = input.get_user_input
    local asked = {}

    input.get_user_input = function(prompt, opts)
      table.insert(asked, { prompt = prompt, default = opts and opts.default })
      return answer
    end

    restore_input = function()
      input.get_user_input = original
    end

    return asked
  end

  ---@return string|nil The last `svn update` command sven ran
  local function last_update_command()
    local history = require("sven.lib.svn").cli.history
    for i = #history, 1, -1 do
      if history[i].cmd:match(" update ") then
        return history[i].cmd
      end
    end
  end

  ---Opens the popup from the status buffer
  local function open_popup()
    t.feed("F")
    assert.are.same("SvenPopup", vim.bo.filetype)
  end

  ---Presses a key of the popup and waits until the status buffer is back
  ---@param key string
  local function press(key)
    t.feed(key)
    t.wait(function()
      return vim.bo.filetype == "SvenStatus"
    end, "the popup to close")
  end

  local restore_notify

  before_each(function()
    wc = harness.create()
    restore_notify = t.silence_notifications()

    -- r3: changes to a.txt, b.txt and src/main.c, and a new file
    other = wc:checkout()
    other:replace("a.txt", "line 18\n", "line 18 from elsewhere\n")
    other:replace("b.txt", "hello", "hello from elsewhere")
    other:replace("src/main.c", "return 0", "return 1")
    other:write("fresh.txt", "fresh\n")
    other:add("fresh.txt")
    other:commit("Change things elsewhere")
  end)

  after_each(function()
    if restore_input then
      restore_input()
      restore_input = nil
    end

    t.close()
    restore_notify()
    harness.cleanup()
  end)

  it("is registered and opens from the status buffer with F", function()
    assert.is_function(require("sven.popups").load("update").create)

    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    t.open(wc)
    t.go("modified     a.txt")

    open_popup()
    local text = table.concat(t.lines(), "\n")

    assert.is_truthy(text:find("-e Ignore externals definitions (--ignore-externals)", 1, true))
    assert.is_truthy(text:find("-f Treat unversioned obstructions as changes (--force)", 1, true))
    assert.is_truthy(
      text:find(
        "-d Change the depth of the working copy (--set-depth=[exclude|empty|files|immediates|infinity])",
        1,
        true
      )
    )
    assert.is_truthy(
      text:find(
        "-a Resolve conflicts as (--accept=[postpone|working|mine-conflict|theirs-conflict|mine-full|theirs-full|base])",
        1,
        true
      )
    )
    assert.is_truthy(text:match("Update %^/trunk to%s+Update only"))
    assert.is_truthy(text:match("u HEAD%s+f a%.txt"))
    assert.is_truthy(text:match("r a revision"))

    t.feed("q")
    t.wait(function()
      return vim.bo.filetype == "SvenStatus"
    end, "the popup to close")
  end)

  it("only offers to update a single path when it was opened on one", function()
    t.open(wc)
    t.go("URL:      " .. wc.url)

    open_popup()
    local text = table.concat(t.lines(), "\n")

    assert.is_truthy(text:match("u HEAD"))
    assert.is_falsy(text:match("Update only"))
  end)

  it("names the number of paths of a selection", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:write("docs/readme.md", "changed\n")
    t.open(wc)

    t.go("modified     a.txt")
    t.feed("VjF")

    assert.are.same("SvenPopup", vim.bo.filetype)
    assert.is_truthy(table.concat(t.lines(), "\n"):match("f 2 selected paths"))
  end)

  it("updates to HEAD, reports the outcome and shows the conflict", function()
    wc:replace("b.txt", "hello", "hello from here")
    t.open(wc)
    open_popup()

    local events
    local notifications = util.capture_notifications(function()
      events = t.capture_events(function()
        press("u")
        t.wait_for_line("Conflicts (1)")
      end)
    end)

    assert.are.same(1, #notifications)
    assert.are.same(
      "Updated to r3 (2 updated, 1 added, 1 conflicted)\n1 conflict:\n  b.txt (text)",
      notifications[1].message
    )
    assert.are.same(vim.log.levels.WARN, notifications[1].level)

    local event = assert(t.event(events, "SvenUpdateComplete"))
    assert.are.same(3, event.data.revision)
    assert.are.same({ { path = "b.txt", text = true, prop = false, tree = false } }, event.data.conflicts)
    assert.are.same(4, #event.data.items)

    -- The status buffer has caught up
    assert.is_true(t.has("conflicted   b.txt"))
    assert.is_true(t.has("Head:     r3 ^/trunk Change things elsewhere"))
    assert.are.same("C", wc:status_of("b.txt"))
    assert.is_true(wc:exists("fresh.txt"))
    assert.are.same(vim.trim(wc:svn("info", "--show-item", "revision")), "3")
  end)

  it("says so when there was nothing to update", function()
    wc:update()
    t.open(wc)
    open_popup()

    local notifications = util.capture_notifications(function()
      press("u")
      t.settle()
    end)

    assert.are.same(1, #notifications)
    assert.are.same("Nothing to update: at r3", notifications[1].message)
    assert.are.same(vim.log.levels.INFO, notifications[1].level)
  end)

  it("updates to a revision that is asked for", function()
    wc:update()
    t.open(wc, { recent = true })
    assert.is_true(t.has("Head:     r3 ^/trunk Change things elsewhere"))

    local asked = answer_revision("r2")
    open_popup()

    local notifications = util.capture_notifications(function()
      press("r")
      t.wait_for_line("Head:     r2 ^/trunk Add the initial files")
    end)

    assert.are.same({ { prompt = "Update to revision" } }, asked)
    assert.are.same("Updated to r2 (3 updated, 1 deleted)", notifications[1].message)
    assert.is_truthy(last_update_command():match(" %-r 2"))
    assert.are.same("hello\n", wc:read("b.txt"))
    assert.is_false(wc:exists("fresh.txt"))
  end)

  it("suggests the revision of the commit under the cursor", function()
    t.open(wc, { recent = true })
    t.go("Recent commits")
    t.feed("<tab>")
    t.go("r3 Change things elsewhere")

    local asked = answer_revision(nil)
    open_popup()
    press("r")
    t.settle()

    assert.are.same({ { prompt = "Update to revision", default = "3" } }, asked)
    -- Cancelled: nothing happened
    assert.are.same("hello\n", wc:read("b.txt"))
  end)

  it("refuses what is not a revision", function()
    t.open(wc)
    answer_revision("the latest")
    open_popup()

    local notifications = util.capture_notifications(function()
      press("r")
      t.settle()
    end)

    assert.are.same(1, #notifications)
    assert.is_truthy(notifications[1].message:match('"the latest" is not a revision'))
    assert.are.same(vim.log.levels.WARN, notifications[1].level)
    assert.are.same("hello\n", wc:read("b.txt"))
  end)

  it("understands the ways to write a revision", function()
    local parse = require("sven.popups.update.actions").parse_revision

    assert.are.same("42", parse("42"))
    assert.are.same("42", parse(" r42 "))
    assert.are.same("HEAD", parse("head"))
    assert.are.same("PREV", parse("PREV"))
    assert.are.same("{2026-10-01}", parse("{2026-10-01}"))
    assert.is_nil(parse("4 2"))
    assert.is_nil(parse("trunk"))
    assert.is_nil(parse(""))
  end)

  it("updates only the file the popup was opened on", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    t.open(wc)
    t.go("modified     a.txt")
    open_popup()

    local notifications = util.capture_notifications(function()
      press("f")
      t.settle()
    end)

    assert.are.same("Updated to r3 (1 merged)", notifications[1].message)
    assert.is_truthy(last_update_command():match(" %-%- a%.txt$"))

    -- a.txt has the incoming change next to the local one, the rest is where it was
    local content = wc:read("a.txt")
    assert.is_truthy(content:match("line 2 changed\n"))
    assert.is_truthy(content:match("line 18 from elsewhere\n"))
    assert.are.same("hello\n", wc:read("b.txt"))
    assert.is_false(wc:exists("fresh.txt"))
  end)

  it("passes its switches on to svn", function()
    t.open(wc)
    open_popup()

    t.feed("-e")
    t.feed("-f")
    -- The depth is picked by cycling through the choices: exclude, empty, files, immediates, infinity
    for _ = 1, 5 do
      t.feed("-d")
    end
    assert.are.same("SvenPopup", vim.bo.filetype)

    press("u")
    t.wait_for_line("Head:     r3 ^/trunk Change things elsewhere")

    local command = last_update_command()
    assert.is_truthy(command:match(" update %-%-accept postpone "))
    assert.is_truthy(command:find(" --ignore-externals", 1, true))
    assert.is_truthy(command:find(" --force", 1, true))
    assert.is_truthy(command:find(" --set-depth=infinity", 1, true))
  end)

  it("resolves conflicts on the way when it is told how", function()
    wc:replace("b.txt", "hello", "hello from here")
    t.open(wc)
    open_popup()

    -- postpone -> working -> mine-conflict -> theirs-conflict -> mine-full -> theirs-full
    for _ = 1, 5 do
      t.feed("-a")
    end

    local notifications = util.capture_notifications(function()
      press("u")
      t.wait_for_line("Head:     r3 ^/trunk Change things elsewhere")
    end)

    assert.is_truthy(last_update_command():match(" update %-%-accept theirs%-full"))
    assert.are.same("Updated to r3 (2 updated, 1 added, 1 conflicted)", notifications[1].message)
    assert.are.same(vim.log.levels.INFO, notifications[1].level)
    assert.are.same("hello from elsewhere\n", wc:read("b.txt"))
    assert.is_false(t.has("Conflicts (1)"))
    assert.are.same({}, wc:status())
  end)

  it("does not remember the depth and the way to resolve conflicts", function()
    -- Specs run without persisted settings. Switch them on for this one.
    local state = require("sven.lib.state")
    local enabled = state._enabled
    state._enabled = true
    state._reset()

    t.open(wc)

    open_popup()
    t.feed("-d")
    t.feed("-a")
    t.feed("-f")
    t.feed("-e")
    assert.are.same(
      { "--ignore-externals", "--force", "--set-depth=exclude", "--accept=working" },
      require("sven.lib.popup").instance:get_arguments()
    )
    t.feed("q")
    t.wait(function()
      return vim.bo.filetype == "SvenStatus"
    end, "the popup to close")

    local popup = require("sven.popups.update").create {}
    local arguments = popup:get_arguments()

    state._reset()
    state._enabled = enabled

    assert.are.same({ "--ignore-externals" }, arguments)
  end)

  it("describes the outcome of an update", function()
    local describe_update = require("sven.popups.update.actions").describe
    local parse = require("sven.lib.svn").update.parse

    local message, level = describe_update(parse {
      "Updating '.':",
      "U    a.txt",
      "A    new.txt",
      "D    old.txt",
      " U   docs",
      "G    merged.txt",
      "C    b.txt",
      "   C tree",
      "Updated to revision 7.",
    })

    assert.are.same(
      "Updated to r7 (2 updated, 1 added, 1 deleted, 1 merged, 2 conflicted)\n2 conflicts:\n  b.txt (text)\n  tree (tree)",
      message
    )
    assert.are.same(vim.log.levels.WARN, level)

    message, level = describe_update(parse { "Updating '.':", "At revision 7." })
    assert.are.same("Nothing to update: at r7", message)
    assert.are.same(vim.log.levels.INFO, level)
  end)

  it("can be run as an action, without the popup", function()
    wc:use()
    wc:refresh()

    local notifications = util.capture_notifications(function()
      require("sven").action("update", "head", { "--ignore-externals" })()
      t.wait(function()
        return wc:exists("fresh.txt")
      end, "the update to finish")
      t.settle()
    end)

    assert.are.same("Updated to r3 (3 updated, 1 added)", notifications[1].message)
    assert.is_truthy(last_update_command():find(" --ignore-externals", 1, true))
  end)
end)
