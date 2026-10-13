local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local t = require("tests.specs.sven.buffers.status_helpers")

describe("popups.resolve", function()
  local wc
  local restore_prompt

  ---Answers every confirmation, and records what was asked
  ---@param answer boolean
  ---@return string[] questions
  local function answer(answer)
    local questions
    questions, restore_prompt = t.answer_permissions(answer)
    return questions
  end

  ---Opens the popup from the status buffer
  local function open_popup()
    t.feed("r")
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

  ---A second conflict, in a.txt: line 5 changed here and in the repository (r4)
  ---@param other SvnHarnessWorkingCopy
  local function make_second_conflict(other)
    other:replace("a.txt", "line 5\n", "line 5 from elsewhere\n")
    other:commit("Change a.txt elsewhere")

    wc:replace("a.txt", "line 5\n", "line 5 from here\n")
    wc:update()
  end

  local restore_notify

  before_each(function()
    wc = harness.create()
    restore_notify = t.silence_notifications()
  end)

  after_each(function()
    if restore_prompt then
      restore_prompt()
      restore_prompt = nil
    end

    t.close()
    restore_notify()
    harness.cleanup()
  end)

  it("is registered and lists the ways to resolve a conflict, with what they do", function()
    assert.is_function(require("sven.popups").load("resolve").create)

    t.make_conflict(wc)
    t.open(wc)
    t.go("conflicted   b.txt")

    open_popup()
    local text = table.concat(t.lines(), "\n")

    assert.is_truthy(text:match("Resolve b%.txt as%s+Resolve all conflicts %(1%) as"))
    assert.is_truthy(text:match("w working%s+the file as it is now, edited by hand%s+W working"))
    assert.is_truthy(
      text:match("m mine%-full%s+my file as a whole, without any incoming change%s+M mine%-full")
    )
    assert.is_truthy(
      text:match("t theirs%-full%s+their file as a whole, dropping all my changes%s+T theirs%-full")
    )
    assert.is_truthy(text:match("b base%s+the file before either side changed it%s+B base"))
    assert.is_truthy(
      text:match("c mine%-conflict%s+both merged, my side where they conflict%s+C mine%-conflict")
    )
    assert.is_truthy(
      text:match("o theirs%-conflict%s+both merged, their side where they conflict%s+O theirs%-conflict")
    )

    -- Every choice of the backend is on offer
    local offered = vim.tbl_map(function(choice)
      return choice.name
    end, require("sven.popups.resolve.actions").choices)
    assert.are.same(require("sven.lib.svn").resolve.choices, offered)
  end)

  it("only offers to resolve everything when it was not opened on a conflict", function()
    t.make_conflict(wc)
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    t.open(wc)
    t.go("modified     a.txt")

    open_popup()
    local text = table.concat(t.lines(), "\n")

    assert.is_falsy(text:match("Resolve b%.txt"))
    assert.is_truthy(text:match("Resolve all conflicts %(1%) as"))
    -- The descriptions are shown in the only column there is
    assert.is_truthy(text:match("T theirs%-full%s+their file as a whole, dropping all my changes"))
    assert.is_falsy(text:match("\nt theirs%-full"))
  end)

  it("says that there is nothing to resolve instead of opening", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    t.open(wc)

    local notifications = util.capture_notifications(function()
      t.feed("r")
    end)

    assert.are.same("SvenStatus", vim.bo.filetype)
    assert.are.same(1, #notifications)
    assert.are.same("There are no conflicts in this working copy", notifications[1].message)
  end)

  it("resolves the file under the cursor with my version, without asking", function()
    t.make_conflict(wc)
    local questions = answer(false)
    t.open(wc)
    t.go("conflicted   b.txt")
    open_popup()

    local events
    local notifications = util.capture_notifications(function()
      events = t.capture_events(function()
        press("m")
        t.wait_for_line("Changes (1)")
      end)
    end)

    assert.are.same({}, questions)
    assert.are.same("Resolved b.txt as mine-full", notifications[1].message)
    assert.are.same("hello from here\n", wc:read("b.txt"))
    assert.are.same({ "M       b.txt" }, wc:status())
    assert.is_false(t.has("Conflicts (1)"))
    assert.is_true(t.has("modified     b.txt"))

    local event = assert(t.event(events, "SvenResolveComplete"))
    assert.are.same({ paths = { "b.txt" }, choice = "mine-full" }, event.data)
  end)

  it("asks before a choice that loses local changes", function()
    t.make_conflict(wc)
    local questions = answer(false)
    t.open(wc)
    t.go("conflicted   b.txt")

    open_popup()
    press("t")
    t.settle()

    assert.are.same({
      'Resolve "b.txt" with theirs-full (their file as a whole, dropping all my changes)? Local changes are lost.',
    }, questions)
    assert.are.same("C", wc:status_of("b.txt"))
    assert.is_true(t.has("Conflicts (1)"))

    -- The same for the other two
    t.go("conflicted   b.txt")
    open_popup()
    press("b")
    t.settle()
    t.go("conflicted   b.txt")
    open_popup()
    press("o")
    t.settle()

    assert.are.same(3, #questions)
    assert.is_truthy(questions[2]:match('^Resolve "b%.txt" with base '))
    assert.is_truthy(questions[3]:match('^Resolve "b%.txt" with theirs%-conflict '))
    assert.are.same("C", wc:status_of("b.txt"))
  end)

  it("takes their version once that is confirmed", function()
    t.make_conflict(wc)
    answer(true)
    t.open(wc)
    t.go("conflicted   b.txt")
    open_popup()

    press("t")
    t.wait_for_no_line("Conflicts (1)")

    assert.are.same("hello from elsewhere\n", wc:read("b.txt"))
    assert.are.same({}, wc:status())
  end)

  it("goes back to the common ancestor", function()
    t.make_conflict(wc)
    answer(true)
    t.open(wc)
    t.go("conflicted   b.txt")
    open_popup()

    press("b")
    t.wait_for_no_line("Conflicts (1)")

    assert.are.same("hello\n", wc:read("b.txt"))
  end)

  it("merges, taking one side where the changes conflict", function()
    local other = wc:checkout()
    other:replace("a.txt", "line 5\n", "line 5 from elsewhere\n")
    other:replace("a.txt", "line 18\n", "line 18 from elsewhere\n")
    other:commit("Change a.txt elsewhere")

    wc:replace("a.txt", "line 5\n", "line 5 from here\n")
    wc:replace("a.txt", "line 12\n", "line 12 from here\n")
    wc:update()

    local questions = answer(true)
    t.open(wc)
    t.go("conflicted   a.txt")
    open_popup()

    press("c")
    t.wait_for_no_line("Conflicts (1)")

    -- No question: nothing of mine is lost
    assert.are.same({}, questions)

    local content = wc:read("a.txt")
    assert.is_truthy(content:match("line 5 from here\n"))
    assert.is_truthy(content:match("line 12 from here\n"))
    assert.is_truthy(content:match("line 18 from elsewhere\n"))
    assert.is_falsy(content:match("<<<<<<<"))
  end)

  it("asks before a file that still has conflict markers is resolved as it is", function()
    t.make_conflict(wc)
    local questions = answer(false)
    t.open(wc)
    t.go("conflicted   b.txt")

    open_popup()
    press("w")
    t.settle()

    assert.are.same({ '"b.txt" still contains conflict markers. Mark it as resolved anyway?' }, questions)
    assert.are.same("C", wc:status_of("b.txt"))

    -- Edited by hand, there is nothing to ask
    wc:write("b.txt", "hello from both\n")
    t.go("conflicted   b.txt")
    open_popup()
    press("w")
    t.wait_for_no_line("Conflicts (1)")

    assert.are.same(1, #questions)
    assert.are.same({ "M       b.txt" }, wc:status())
    assert.are.same("hello from both\n", wc:read("b.txt"))
  end)

  it("resolves every conflict with the upper case keys", function()
    local other = t.make_conflict(wc)
    make_second_conflict(other)
    wc:replace("src/main.c", "return 0", "return 1")

    local questions = answer(true)
    t.open(wc)
    assert.is_true(t.has("Conflicts (2)"))

    -- Not on a conflict
    t.go("modified     src/main.c")
    open_popup()
    assert.is_truthy(table.concat(t.lines(), "\n"):match("Resolve all conflicts %(2%) as"))

    local notifications = util.capture_notifications(function()
      press("T")
      t.wait_for_no_line("Conflicts (2)")
    end)

    assert.are.same({
      "Resolve these 2 conflicts with theirs-full (their file as a whole, dropping all my changes)? "
        .. "Local changes are lost.\n  a.txt\n  b.txt",
    }, questions)
    assert.are.same("Resolved 2 conflicts as theirs-full", notifications[1].message)
    assert.are.same({ "M       src/main.c" }, wc:status())
    assert.are.same("hello from elsewhere\n", wc:read("b.txt"))
    assert.is_truthy(wc:read("a.txt"):match("line 5 from elsewhere\n"))
  end)

  it("resolves the conflicts of a selection", function()
    local other = t.make_conflict(wc)
    make_second_conflict(other)
    answer(true)
    t.open(wc)

    t.go("conflicted   a.txt")
    t.feed("Vjr")
    assert.are.same("SvenPopup", vim.bo.filetype)
    assert.is_truthy(table.concat(t.lines(), "\n"):match("Resolve 2 selected conflicts as"))

    press("m")
    t.wait_for_line("Changes (2)")

    assert.are.same({ "M       a.txt", "M       b.txt" }, wc:status())
    assert.is_truthy(wc:read("a.txt"):match("line 5 from here\n"))
  end)

  it("only resolves the conflict it was opened on with the lower case keys", function()
    local other = t.make_conflict(wc)
    make_second_conflict(other)
    t.open(wc)

    t.go("conflicted   b.txt")
    open_popup()
    press("m")
    t.wait_for_line("Conflicts (1)")

    assert.are.same("C", wc:status_of("a.txt"))
    assert.are.same("M", wc:status_of("b.txt"))
  end)

  it("says why a tree conflict cannot be resolved by taking a side", function()
    -- Edited here, deleted in the repository
    local other = wc:checkout()
    other:delete("docs/readme.md")
    other:commit("Delete the readme")
    wc:replace("docs/readme.md", "Some text.", "Some edited text.")
    wc:update()

    local questions = answer(true)
    t.open(wc)
    t.go("added        docs/readme.md (tree conflict, copied)")

    open_popup()
    local notifications = util.capture_notifications(function()
      press("t")
      t.settle()
    end)

    assert.are.same({}, questions)
    assert.are.same(1, #notifications)
    assert.is_truthy(notifications[1].message:match("^Tree conflicts cannot be resolved with theirs%-full"))
    assert.is_truthy(notifications[1].message:match("docs/readme%.md"))
    assert.is_true(t.has("Conflicts (1)"))

    -- As it is, it can
    t.go("added        docs/readme.md (tree conflict, copied)")
    open_popup()
    press("w")
    t.wait_for_no_line("Conflicts (1)")
    assert.is_true(t.has("added        docs/readme.md (copied)"))
  end)

  it("can be opened by name, and run as an action", function()
    t.make_conflict(wc)
    wc:use()
    wc:refresh()

    vim.cmd("Sven resolve cwd=" .. wc.path)
    t.wait(function()
      return vim.bo.filetype == "SvenPopup"
    end, "the popup to open")
    assert.is_truthy(table.concat(t.lines(), "\n"):match("W working%s+the file as it is now"))
    t.feed("q")
    t.settle()

    require("sven").action("resolve", "all_mine_full")()
    t.wait(function()
      return wc:status_of("b.txt") == "M"
    end, "the conflict to be resolved")
    t.settle()

    assert.are.same("hello from here\n", wc:read("b.txt"))
  end)
end)
