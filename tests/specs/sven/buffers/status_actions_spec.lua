local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local t = require("tests.specs.sven.buffers.status_helpers")

local STAGING = "sven-staged"

describe("buffers.status actions", function()
  local wc
  local restore_prompt

  ---Answers every confirmation, and records what was asked
  ---@param answer boolean|fun(message: string): boolean
  ---@return string[] questions
  local function answer(answer)
    if restore_prompt then
      restore_prompt()
    end

    local questions
    questions, restore_prompt = t.answer_permissions(answer)
    return questions
  end

  ---@param section string A section title, e.g. "Staged changes (1)"
  ---@return string[] The lines of that section, without its title and the empty line that ends it
  local function section_lines(section)
    local first =
      assert(t.find(section), "No section " .. section .. " in:\n" .. table.concat(t.lines(), "\n"))
    local lines = {}

    for _, line in ipairs(vim.list_slice(t.lines(), first + 1)) do
      if line == "" then
        break
      end

      table.insert(lines, line)
    end

    return lines
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

  describe("stage", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/sub/y.txt", "y\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("review", "src/main.c")
    end)

    it("stages the file under the cursor", function()
      t.open(wc)
      t.go("modified     a.txt")

      t.feed("s")

      t.wait_for_line("Staged changes (1)")
      assert.are.same({ "modified     a.txt" }, section_lines("Staged changes (1)"))
      assert.are.same({ "modified     b.txt" }, section_lines("Changes (1)"))
      assert.are.same({ "a.txt" }, wc:members(STAGING))
    end)

    it("adds and stages an unversioned file", function()
      t.open(wc)
      t.go("new.txt")

      t.feed("s")

      t.wait_for_line("Staged changes (1)")
      assert.are.same({ "added        new.txt" }, section_lines("Staged changes (1)"))
      assert.are.same({ "newdir/" }, section_lines("Unversioned files (1)"))
      assert.are.same("A", wc:status_of("new.txt"))
      assert.are.same({ "new.txt" }, wc:members(STAGING))
    end)

    it("adds an unversioned directory and stages the files in it", function()
      t.open(wc)
      t.go("newdir/")

      t.feed("s")

      t.wait_for_line("Staged changes (4)")
      assert.are.same({
        "added        newdir/ (needed by staged files)",
        "added        newdir/sub/ (needed by staged files)",
        "added        newdir/sub/y.txt",
        "added        newdir/x.txt",
      }, section_lines("Staged changes (4)"))
      assert.are.same({ "newdir/sub/y.txt", "newdir/x.txt" }, wc:members(STAGING))
      assert.are.same("A", wc:status_of("newdir"))
    end)

    it("moves a file over from another changelist", function()
      t.open(wc)
      t.go("modified     src/main.c")

      t.feed("s")

      t.wait_for_line("Staged changes (1)")
      assert.is_false(t.has("Changelist review (1)"))
      assert.are.same({ "src/main.c" }, wc:members(STAGING))
      assert.are.same({}, wc:members("review"))
    end)

    it("stages a whole section from its header", function()
      t.open(wc)

      t.go("Changes (2)")
      t.feed("s")
      t.wait_for_line("Staged changes (2)")
      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGING))
      assert.is_false(t.has("Changes (2)"))

      t.go("Unversioned files (2)")
      t.feed("s")
      t.wait_for_line("Staged changes (7)")
      assert.are.same(
        { "a.txt", "b.txt", "new.txt", "newdir/sub/y.txt", "newdir/x.txt" },
        wc:members(STAGING)
      )

      t.go("Changelist review (1)")
      t.feed("s")
      t.wait_for_line("Staged changes (8)")
      assert.are.same({}, wc:members("review"))
    end)

    it("stages the whole file when asked for a hunk, and says so", function()
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      -- Inside the second hunk
      vim.api.nvim_win_set_cursor(0, { line + 12, 0 })
      assert.are.same("-line 18", vim.api.nvim_get_current_line())

      local notifications = util.capture_notifications(function()
        t.feed("s")
        t.wait_for_line("Staged changes (1)")
      end)

      assert.are.same(1, #notifications)
      assert.are.same(
        "Staged all of a.txt: Subversion cannot stage parts of a file",
        notifications[1].message
      )
      assert.are.same(vim.log.levels.INFO, notifications[1].level)
      assert.are.same({ "a.txt" }, wc:members(STAGING))
    end)

    it("stages the files of a visual selection", function()
      t.open(wc)

      t.go("modified     a.txt")
      t.feed("V")
      t.go("modified     b.txt")
      t.feed("s")

      t.wait_for_line("Staged changes (2)")
      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGING))
      assert.are.same("n", vim.fn.mode())
    end)

    it("stages the whole file for a selection inside its diff, and says so", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      vim.api.nvim_win_set_cursor(0, { line + 3, 0 })
      local notifications = util.capture_notifications(function()
        t.feed("Vjs")
        t.wait_for_line("Staged changes (1)")
      end)

      assert.are.same(
        "Staged all of a.txt: Subversion cannot stage parts of a file",
        notifications[1].message
      )
      assert.are.same({ "a.txt" }, wc:members(STAGING))
    end)

    it("stages the versioned changes with S, everything with <c-s>", function()
      t.open(wc)

      t.feed("S")
      t.wait_for_line("Staged changes (2)")
      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGING))
      assert.is_true(t.has("Unversioned files (2)"))
      assert.are.same({ "src/main.c" }, wc:members("review"))

      t.feed("<c-s>")
      t.wait_for_line("Staged changes (7)")
      assert.is_false(t.has("Unversioned files (2)"))
      -- Other changelists are not raided
      assert.are.same({ "src/main.c" }, wc:members("review"))
    end)

    it("does nothing on what is staged already, or on a commit", function()
      wc:changelist(STAGING, "a.txt")
      t.open(wc, { recent = true })

      t.go("modified     a.txt")
      t.feed("s")
      t.go("Recent commits")
      t.feed("<tab>j")
      t.feed("s")
      t.settle()

      assert.are.same({ "a.txt" }, wc:members(STAGING))
      assert.is_true(t.has("Staged changes (1)"))
    end)
  end)

  describe("stage a conflict", function()
    before_each(function()
      t.make_conflict(wc)
    end)

    it("asks before a file that still has conflict markers is marked as resolved", function()
      local questions = answer(false)
      t.open(wc)
      t.go("conflicted   b.txt")

      t.feed("s")
      t.settle()

      assert.are.same({ '"b.txt" still contains conflict markers. Mark it as resolved anyway?' }, questions)
      assert.are.same("C", wc:status_of("b.txt"))
      assert.is_true(t.has("Conflicts (1)"))
    end)

    it("resolves the file as it is and stages it when that is confirmed", function()
      answer(true)
      t.open(wc)
      t.go("conflicted   b.txt")

      local events = t.capture_events(function()
        t.feed("s")
        t.wait_for_line("Staged changes (1)")
      end)

      assert.is_false(t.has("Conflicts (1)"))
      assert.are.same({ "modified     b.txt" }, section_lines("Staged changes (1)"))
      assert.are.same("M", wc:status_of("b.txt"))
      assert.are.same({ "b.txt" }, wc:members(STAGING))
      -- The files svn put next to it are gone
      assert.is_false(wc:exists("b.txt.mine"))
      assert.is_false(t.has("Unversioned files (1)"))

      local event = assert(t.event(events, "SvenResolveComplete"))
      assert.are.same({ paths = { "b.txt" }, choice = "working" }, event.data)
    end)

    it("does not ask about a file that has been edited into shape", function()
      local questions = answer(false)
      wc:write("b.txt", "hello from both\n")
      t.open(wc)
      t.go("conflicted   b.txt")

      local notifications = util.capture_notifications(function()
        t.feed("s")
        t.wait_for_line("Staged changes (1)")
      end)

      assert.are.same({}, questions)
      assert.are.same("M", wc:status_of("b.txt"))
      assert.are.same({ "b.txt" }, wc:members(STAGING))
      assert.are.same("Resolved b.txt as working and staged it", notifications[1].message)
    end)

    it("resolves and stages every conflict from the section header", function()
      local questions = answer(true)
      t.open(wc)
      t.go("Conflicts (1)")

      t.feed("s")
      t.wait_for_line("Staged changes (1)")

      assert.are.same(1, #questions)
      assert.are.same("M", wc:status_of("b.txt"))
    end)
  end)

  describe("unstage", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGING, "a.txt", "b.txt")
    end)

    it("unstages the file under the cursor", function()
      t.open(wc)
      t.go("modified     a.txt")

      t.feed("u")

      t.wait_for_line("Staged changes (1)")
      assert.are.same({ "modified     b.txt" }, section_lines("Staged changes (1)"))
      assert.are.same({ "modified     a.txt", "modified     src/main.c" }, section_lines("Changes (2)"))
      assert.are.same({ "b.txt" }, wc:members(STAGING))
    end)

    it("unstages the section from its header, and everything with U", function()
      t.open(wc)

      t.go("Staged changes (2)")
      t.feed("u")
      t.wait_for_line("Changes (3)")
      assert.are.same({}, wc:members(STAGING))

      wc:changelist(STAGING, "a.txt", "b.txt")
      t.feed("<c-r>")
      t.wait_for_line("Staged changes (2)")

      t.go("modified     src/main.c")
      t.feed("U")
      t.wait_for_line("Changes (3)")
      assert.are.same({}, wc:members(STAGING))
    end)

    it("unstages the files of a visual selection", function()
      t.open(wc)

      t.go("modified     a.txt")
      t.feed("Vju")

      t.wait_for_line("Changes (3)")
      assert.are.same({}, wc:members(STAGING))
    end)

    it("unstages the whole file when asked for a hunk, and says so", function()
      t.open(wc)
      t.go("modified     a.txt")
      t.feed("<tab>jj")

      local notifications = util.capture_notifications(function()
        t.feed("u")
        t.wait_for_line("Changes (2)")
      end)

      assert.are.same(
        "Unstaged all of a.txt: Subversion cannot unstage parts of a file",
        notifications[1].message
      )
      assert.are.same({ "b.txt" }, wc:members(STAGING))
    end)

    it("unstages the files below a directory that is staged because of them", function()
      wc:write("newdir/x.txt", "x\n")
      wc:add("newdir")
      wc:changelist(STAGING, "newdir/x.txt")
      t.open(wc)
      t.go("added        newdir/ (needed by staged files)")

      t.feed("u")

      t.wait_for_line("Staged changes (2)")
      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGING))
      -- Still scheduled for addition
      assert.are.same("A", wc:status_of("newdir/x.txt"))
    end)

    it("does nothing outside of the staged changes", function()
      t.open(wc)
      t.go("modified     src/main.c")

      t.feed("u")
      t.settle()

      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGING))
      assert.is_true(t.has("Staged changes (2)"))
    end)
  end)

  describe("discard", function()
    it("deletes an unversioned file, after asking", function()
      wc:write("new.txt", "new\n")
      local questions = answer(true)
      t.open(wc)
      t.go("new.txt")

      t.feed("x")

      t.wait_for_no_line("new.txt")
      assert.are.same({ 'Delete the unversioned file "new.txt"?' }, questions)
      assert.is_false(wc:exists("new.txt"))
      assert.is_false(t.has("Unversioned files (1)"))
    end)

    it("leaves everything alone when the question is answered with no", function()
      wc:write("new.txt", "new\n")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      local questions = answer(false)
      t.open(wc)

      t.go("new.txt")
      t.feed("x")
      t.go("modified     a.txt")
      t.feed("x")
      t.go("Changes (1)")
      t.feed("x")
      t.settle()

      assert.are.same(3, #questions)
      assert.is_true(wc:exists("new.txt"))
      assert.are.same("M", wc:status_of("a.txt"))
    end)

    it("deletes an unversioned directory with everything in it", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/sub/y.txt", "y\n")
      local questions = answer(true)
      t.open(wc)
      t.go("newdir/")

      t.feed("x")

      t.wait_for_no_line("newdir/")
      assert.are.same({ 'Delete the unversioned directory "newdir/" and everything in it?' }, questions)
      assert.is_false(wc:exists("newdir"))
    end)

    it("reverts a modified file", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      local questions = answer(true)
      t.open(wc)
      t.go("modified     a.txt")

      local events = t.capture_events(function()
        t.feed("x")
        t.wait_for_line("Changes (1)")
      end)

      assert.are.same({ 'Discard all changes to "a.txt"?' }, questions)
      assert.are.same({ "modified     b.txt" }, section_lines("Changes (1)"))
      assert.are.same("", wc:status_of("a.txt"))
      assert.is_truthy(wc:read("a.txt"):match("line 2\n"))

      -- Other views are told
      local event = assert(t.event(events, "SvenRevertComplete"))
      assert.are.same({ paths = { "a.txt" } }, event.data)
    end)

    it("reverts a staged file, which is not staged afterwards", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:changelist(STAGING, "a.txt")
      answer(true)
      t.open(wc)
      t.go("modified     a.txt")

      t.feed("x")

      t.wait_for_no_line("Staged changes (1)")
      assert.are.same("", wc:status_of("a.txt"))
      assert.are.same({}, wc:members(STAGING))
    end)

    it("undoes an addition, leaving the file on disk", function()
      wc:write("new.txt", "new\n")
      wc:add("new.txt")
      local questions = answer(true)
      t.open(wc)
      t.go("added        new.txt")

      t.feed("x")

      t.wait_for_line("Unversioned files (1)")
      assert.are.same({ 'Undo the addition of "new.txt"? The file stays on disk, unversioned.' }, questions)
      assert.are.same("?", wc:status_of("new.txt"))
      assert.are.same("new\n", wc:read("new.txt"))
      assert.are.same({ "new.txt" }, section_lines("Unversioned files (1)"))
    end)

    it("restores deleted and missing files", function()
      wc:delete("b.txt")
      wc:remove("src/main.c")
      local questions = answer(true)
      t.open(wc)

      t.go("deleted      b.txt")
      t.feed("x")
      t.wait_for_line("Changes (1)")

      t.go("missing      src/main.c")
      t.feed("x")
      t.wait_for_no_line("Changes (1)")

      assert.are.same({ 'Undo the deletion of "b.txt"?', 'Restore the missing "src/main.c"?' }, questions)
      assert.are.same("hello\n", wc:read("b.txt"))
      assert.is_true(wc:exists("src/main.c"))
      assert.are.same({}, wc:status())
    end)

    it("discards the property change of a directory without touching what is below it", function()
      wc:propset("svn:ignore", "*.o", "src")
      wc:replace("src/main.c", "return 0", "return 1")
      local questions = answer(true)
      t.open(wc)
      t.go("modified     src/ (properties)")

      t.feed("x")

      t.wait_for_line("Changes (1)")
      assert.are.same({ 'Discard the property changes of "src/"?' }, questions)
      assert.are.same({ "modified     src/main.c" }, section_lines("Changes (1)"))
      assert.are.same("M", wc:status_of("src/main.c"))
      assert.are.same("", wc:status_of("src"))
    end)

    it("discards the hunk under the cursor", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      local questions = answer(true)
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      -- Inside the second hunk
      vim.api.nvim_win_set_cursor(0, { line + 12, 0 })
      assert.are.same("-line 18", vim.api.nvim_get_current_line())

      t.feed("x")
      t.wait_for_no_line("+line 18 changed")

      assert.are.same({ 'Discard this hunk of "a.txt"?\n  @@ -15,6 +15,6 @@' }, questions)

      local content = wc:read("a.txt")
      assert.is_truthy(content:match("line 2 changed\n"))
      assert.is_truthy(content:match("line 18\n"))
      assert.is_falsy(content:match("line 18 changed"))

      -- The file is still unfolded, with the hunk that is left
      assert.is_true(t.has("+line 2 changed"))
      assert.are.same("M", wc:status_of("a.txt"))
    end)

    it("discards the last hunk of a file, which leaves it unmodified", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      answer(true)
      t.open(wc)
      t.go("modified     a.txt")
      t.feed("<tab>j")

      t.feed("x")

      t.wait_for_no_line("Changes (1)")
      assert.are.same({}, wc:status())
    end)

    it("discards the selected lines of a hunk", function()
      wc:replace("a.txt", "line 2\nline 3\n", "line 2 changed\nline 3 changed\n")
      local questions = answer(true)
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      assert.are.same({
        "@@ -1,6 +1,6 @@",
        " line 1",
        "-line 2",
        "-line 3",
        "+line 2 changed",
        "+line 3 changed",
        " line 4",
      }, vim.list_slice(t.lines(), line + 1, line + 7))

      -- "-line 3" and "+line 2 changed": line 3 comes back, the change of line 2 goes
      vim.api.nvim_win_set_cursor(0, { line + 4, 0 })
      t.feed("Vjx")
      t.wait_for_line(" line 3")

      assert.are.same({ 'Discard the selected lines of "a.txt"?' }, questions)
      assert.are.same(
        "line 1\nline 3\nline 3 changed\nline 4\n",
        wc:read("a.txt"):match("^line 1\n.-line 4\n")
      )
    end)

    it("discards the selected lines of several hunks at once", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      answer(true)
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      -- From "+line 2 changed" in the first hunk to "-line 18" in the second
      vim.api.nvim_win_set_cursor(0, { line + 4, 0 })
      t.feed("V")
      vim.api.nvim_win_set_cursor(0, { line + 12, 0 })
      t.feed("x")
      t.wait_for_no_line("+line 2 changed")

      local content = wc:read("a.txt")
      -- The addition of the first hunk is gone, its deletion is not selected and stays
      assert.is_truthy(content:match("^line 1\nline 3\n"))
      -- The deletion of the second hunk is undone, its addition stays
      assert.is_truthy(content:match("line 18\nline 18 changed\n"))
    end)

    it("explains why a hunk of an added file cannot be discarded", function()
      wc:write("new.txt", "first\nsecond\n")
      wc:add("new.txt")
      local questions = answer(true)
      t.open(wc)
      t.go("added        new.txt")
      t.feed("<tab>jj")

      local notifications = util.capture_notifications(function()
        t.feed("x")
        t.settle()
      end)

      assert.are.same({}, questions)
      assert.are.same(1, #notifications)
      assert.are.same(
        "new.txt is added, as a whole. Discard the file to undo the addition.",
        notifications[1].message
      )
      assert.are.same("A", wc:status_of("new.txt"))

      -- The same for a selection
      notifications = util.capture_notifications(function()
        t.feed("Vx")
        t.settle()
      end)

      assert.are.same({}, questions)
      assert.are.same(
        "new.txt is added, as a whole. Discard the file to undo the addition.",
        notifications[1].message
      )
    end)

    it("explains that property changes are not hunks", function()
      wc:propset("color", "blue", "a.txt")
      local questions = answer(true)
      t.open(wc)
      t.go("modified     a.txt (properties)")
      t.feed("<tab>j")

      local notifications = util.capture_notifications(function()
        t.feed("x")
        t.settle()
      end)

      assert.are.same({}, questions)
      assert.is_truthy(
        notifications[1].message:match("Property changes can only be discarded with the rest of")
      )
      assert.are.same("M", wc:status_of("a.txt"))
    end)

    it("discards a hunk of a file that also has property changes", function()
      wc:propset("color", "blue", "a.txt")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      answer(true)
      t.open(wc)
      t.go("modified     a.txt (+properties)")
      t.feed("<tab>")

      t.go("+line 2 changed")
      t.feed("x")
      t.wait_for_line("modified     a.txt (properties)")

      assert.is_falsy(wc:read("a.txt"):match("line 2 changed"))
      assert.are.same("blue", vim.trim(wc:svn("propget", "color", "a.txt")))
    end)

    it("discards a whole section from its header, naming what is lost", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:delete("b.txt")
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      local questions = answer(true)
      t.open(wc)

      t.go("Changes (2)")
      t.feed("x")
      t.wait_for_no_line("Changes (2)")

      assert.are.same(
        "Discard all changes to these 2 items?\n  modified     a.txt\n  deleted      b.txt",
        questions[1]
      )
      assert.are.same({ "?       new.txt", "?       newdir" }, wc:status())

      t.go("Unversioned files (2)")
      t.feed("x")
      t.wait_for_no_line("Unversioned files (2)")

      assert.are.same(
        "Delete these 2 unversioned items from disk?\n  unversioned  new.txt\n  unversioned  newdir/",
        questions[2]
      )
      assert.are.same({}, wc:status())
      assert.is_false(wc:exists("newdir"))
    end)

    it("discards the files of a visual selection", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:write("new.txt", "new\n")
      local questions = answer(true)
      t.open(wc)

      t.go("new.txt")
      t.feed("V")
      t.go("modified     a.txt")
      t.feed("x")
      t.wait_for_line("Changes (1)")

      assert.are.same({ "Discard these 2 items?\n  unversioned  new.txt\n  modified     a.txt" }, questions)
      assert.are.same({ "M       b.txt" }, wc:status())
    end)

    it("reverts a conflicted file, which drops the conflict", function()
      t.make_conflict(wc)
      local questions = answer(true)
      t.open(wc)
      t.go("conflicted   b.txt")

      t.feed("x")

      t.wait_for_no_line("Conflicts (1)")
      assert.are.same({ 'Discard all local changes to "b.txt" and drop its conflict?' }, questions)
      assert.are.same({}, wc:status())
      assert.are.same("hello from elsewhere\n", wc:read("b.txt"))
    end)

    it("does nothing on a commit", function()
      local questions = answer(true)
      t.open(wc, { recent = true })
      t.go("Recent commits")
      t.feed("<tab>j")

      t.feed("x")
      t.settle()

      assert.are.same({}, questions)
    end)
  end)
end)
