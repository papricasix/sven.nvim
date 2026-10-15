local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local t = require("tests.specs.sven.buffers.status_helpers")

---@param line integer 1-based
---@return string[] The highlight groups applied to parts of a line of the current buffer
local function highlights_on(line)
  local groups = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(0, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true }))
  do
    if mark[4].hl_group then
      table.insert(groups, mark[4].hl_group)
    end
  end

  return groups
end

describe("buffers.status", function()
  local wc, status

  before_each(function()
    wc = harness.create()
    status = require("sven.buffers.status")
  end)

  after_each(function()
    t.close()
    t.unstub_modules()
    harness.cleanup()
  end)

  describe("contract", function()
    it("offers what the rest of the plugin calls", function()
      local instance = t.open(wc)

      for _, name in ipairs {
        "open",
        "close",
        "focus",
        "refresh",
        "dispatch_refresh",
        "redraw",
        "reset",
        "dispatch_reset",
        "id",
      } do
        assert.is_function(instance[name], name)
      end

      assert.is_function(status.new)
      assert.is_function(status.instance)
      assert.is_function(status.is_open)

      assert.are.same("StatusBuffer", instance:id())
      assert.are.same(wc.path, instance.root)
      assert.are.same(wc.path, instance.cwd)
      assert.are.equal(instance, status.new(require("sven.config").values, wc.path, wc.path))
    end)

    it("is a read-only buffer in the directory of the working copy", function()
      t.open(wc)

      assert.are.same("SvenStatus", vim.bo.filetype)
      assert.are.same("nofile", vim.bo.buftype)
      assert.is_false(vim.bo.modifiable)
      assert.is_true(vim.bo.readonly)
      assert.are.same(wc.path, vim.fn.getcwd(0))
      assert.is_true(status.is_open())
    end)

    it("opens in the kind it is told to", function()
      t.open(wc, { kind = "tab" })
      assert.are.same(2, #vim.api.nvim_list_tabpages())
      t.feed("q")
      t.wait(function()
        return #vim.api.nvim_list_tabpages() == 1
      end, "the tab to close")

      t.open(wc, { kind = "vsplit" })
      assert.are.same("row", vim.fn.winlayout()[1])
      t.feed("q")
      t.wait(function()
        return vim.bo.filetype ~= "SvenStatus"
      end, "the split to close")

      t.open(wc, { kind = "floating" })
      assert.are_not.same("", vim.api.nvim_win_get_config(0).relative)
    end)

    it("focuses the buffer that is open instead of opening another", function()
      local instance = t.open(wc)
      local windows = #vim.api.nvim_tabpage_list_wins(0)

      vim.cmd("wincmd p")
      assert.are_not.same("SvenStatus", vim.bo.filetype)

      instance:open("split")
      assert.are.same("SvenStatus", vim.bo.filetype)
      assert.are.same(windows, #vim.api.nvim_tabpage_list_wins(0))
    end)
  end)

  describe("rendering", function()
    it("shows the header and every section", function()
      t.make_conflict(wc)
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      wc:delete("noeol.txt")
      wc:remove("src/sub/util.c")
      wc:propset("svn:ignore", "*.o", "src")
      wc:write("other.txt", "other\n")
      wc:add("other.txt")
      wc:changelist("review", "other.txt")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("sven-staged", "src/main.c")

      t.open(wc, { recent = true })

      assert.are.same({
        "Hint: <tab> za toggle | s stage | u unstage | x discard | c commit | ? help",
        "",
        "Head:     r3 ^/trunk Change b.txt elsewhere",
        "URL:      " .. wc.url,
        "",
        "Conflicts (1)",
        "conflicted   b.txt",
        "",
        "Unversioned files (2)",
        "new.txt",
        "newdir/",
        "",
        "Changes (4)",
        "modified     a.txt",
        "deleted      noeol.txt",
        "modified     src/ (properties)",
        "missing      src/sub/util.c",
        "",
        "Changelist review (1)",
        "added        other.txt",
        "",
        "Staged changes (1)",
        "modified     src/main.c",
        "",
        "Recent commits",
        "r3 Change b.txt elsewhere",
        "r2 Add the initial files",
        "r1 Create the layout",
        "",
      }, t.lines())

      -- The files svn left next to the conflicted one are not listed
      assert.is_falsy(table.concat(t.lines(), "\n"):match("b%.txt%.mine"))
    end)

    it("highlights the header and the items by what they are", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("other.txt", "other\n")
      wc:add("other.txt")
      wc:changelist("review", "other.txt")
      t.open(wc)

      local head = highlights_on(t.find("Head:     r2 ^/trunk Add the initial files"))
      assert.is_true(vim.tbl_contains(head, "SvenStatusHEAD"))
      assert.is_true(vim.tbl_contains(head, "SvenRevision"))
      assert.is_true(vim.tbl_contains(head, "SvenBranch"))
      assert.is_true(vim.tbl_contains(highlights_on(t.find("URL:      " .. wc.url)), "SvenUrl"))

      assert.is_true(vim.tbl_contains(highlights_on(t.find("Changes (1)")), "SvenChanges"))
      assert.is_true(vim.tbl_contains(highlights_on(t.find("modified     a.txt")), "SvenChangeModified"))
      assert.is_true(vim.tbl_contains(highlights_on(t.find("added        other.txt")), "SvenChangeAdded"))

      local changelist = highlights_on(t.find("Changelist review (1)"))
      assert.is_true(vim.tbl_contains(changelist, "SvenChangelist"))
      assert.is_true(vim.tbl_contains(changelist, "SvenChangelistName"))
    end)

    it("shows the commit the working copy is at, not one it has not been updated to", function()
      local other = wc:checkout()
      other:replace("b.txt", "hello", "hello from elsewhere")
      other:commit("Change b.txt elsewhere")

      t.open(wc, { recent = true })

      assert.is_true(t.has("Head:     r2 ^/trunk Add the initial files"))
      assert.is_true(t.has("r3 Change b.txt elsewhere"))
    end)

    it("marks copies, moves, switched paths and the kind of a conflict", function()
      -- A tree conflict: edited here, deleted in the repository
      local other = wc:checkout()
      other:delete("docs/readme.md")
      other:commit("Delete the readme")
      wc:replace("docs/readme.md", "Some text.", "Some edited text.")
      wc:update()

      -- A property conflict
      other:propset("color", "red", "src/main.c")
      other:commit("Set a property")
      wc:propset("color", "blue", "src/main.c")
      wc:update()

      wc:svn("copy", "a.txt", "copy.txt")
      wc:svn("move", "b.txt", "moved.txt")

      harness.svn({ "copy", "-q", "-m", "Branch", wc.url, wc.repo_url .. "/branches/b" }, wc.path)
      wc:svn("switch", "-q", wc.repo_url .. "/branches/b/src/sub", "src/sub")
      wc:propset("color", "green", "src/sub")

      t.open(wc)
      local lines = t.lines()

      assert.is_true(
        vim.tbl_contains(lines, "added        docs/readme.md (tree conflict, copied)"),
        vim.inspect(lines)
      )
      assert.is_true(
        vim.tbl_contains(lines, "conflicted   src/main.c (property conflict)"),
        vim.inspect(lines)
      )
      assert.is_true(vim.tbl_contains(lines, "added        copy.txt (copied)"), vim.inspect(lines))
      assert.is_true(vim.tbl_contains(lines, "deleted      b.txt (moved to moved.txt)"), vim.inspect(lines))
      assert.is_true(vim.tbl_contains(lines, "added        b.txt -> moved.txt"), vim.inspect(lines))
      assert.is_true(
        vim.tbl_contains(lines, "modified     src/sub/ (properties, switched)"),
        vim.inspect(lines)
      )
    end)

    it("marks the directories that are staged because of the files in them", function()
      wc:write("newdir/x.txt", "x\n")
      wc:add("newdir")
      wc:changelist("sven-staged", "newdir/x.txt")
      t.open(wc)

      local line = t.find("Staged changes (2)")
      assert.are.same({
        "Staged changes (2)",
        "added        newdir/ (needed by staged files)",
        "added        newdir/x.txt",
        "",
      }, vim.list_slice(t.lines(), line, line + 3))
    end)

    it("honours the hint switch and the section configuration", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist("sven-staged", "b.txt")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("review", "src/main.c")

      harness.setup {
        disable_hint = true,
        sections = {
          unversioned = { folded = false, hidden = true },
          changes = { folded = true, hidden = false },
          changelists = { folded = false, hidden = true },
          recent = { folded = true, hidden = true },
        },
      }

      t.open(wc)
      wc:wait_for_recent()
      t.settle()

      assert.are.same({
        "Head:     r2 ^/trunk Add the initial files",
        "URL:      " .. wc.url,
        "",
        "Changes (1)",
        "modified     a.txt",
        "",
        "Staged changes (1)",
        "modified     b.txt",
        "",
      }, t.lines())
    end)

    it("folds the sections that are configured to be folded", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist("sven-staged", "b.txt")

      harness.setup { sections = { changes = { folded = true, hidden = false } } }
      t.open(wc, { recent = true })

      local changes = t.find("Changes (1)")
      local staged = t.find("Staged changes (1)")
      local recent = t.find("Recent commits")

      assert.are.same(changes, vim.fn.foldclosed(changes))
      assert.are.same(-1, vim.fn.foldclosed(staged))
      -- Folded by default
      assert.are.same(recent, vim.fn.foldclosed(recent))
    end)

    it("shows the recent commits once they have been fetched", function()
      t.open(wc, { recent = true })

      assert.are.same({
        "Recent commits",
        "r2 Add the initial files",
        "r1 Create the layout",
        "",
      }, vim.list_slice(t.lines(), t.find("Recent commits")))
    end)
  end)

  describe("folding", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      wc:replace("b.txt", "hello", "bye")
    end)

    it("unfolds a file to its diff, which is loaded when it is first shown", function()
      t.open(wc)

      local item = require("sven.lib.svn").status.find("a.txt")
      assert.is_nil(rawget(item, "diff"))

      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      assert.is_not_nil(rawget(item, "diff"))
      assert.are.same({
        "modified     a.txt",
        "@@ -1,5 +1,5 @@",
        " line 1",
        "-line 2",
        "+line 2 changed",
        " line 3",
        " line 4",
        " line 5",
        "@@ -15,6 +15,6 @@",
        " line 15",
        " line 16",
        " line 17",
        "-line 18",
        "+line 18 changed",
        " line 19",
        " line 20",
        "modified     b.txt",
      }, vim.list_slice(t.lines(), line, line + 16))

      -- The lines of the diff are highlighted as such
      assert.is_true(vim.tbl_contains(highlights_on(line + 1), "SvenHunkHeader"))
      assert.is_true(vim.tbl_contains(highlights_on(line + 3), "SvenDiffDelete"))
      assert.is_true(vim.tbl_contains(highlights_on(line + 4), "SvenDiffAdd"))
    end)

    it("folds a file again, and its hunks one by one", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")
      assert.are.same(-1, vim.fn.foldclosed(line))

      -- The second hunk
      vim.api.nvim_win_set_cursor(0, { line + 10, 0 })
      t.feed("<tab>")
      assert.are.same(line + 8, vim.fn.foldclosed(line + 10))
      assert.are.same(line + 15, vim.fn.foldclosedend(line + 10))
      assert.are.same(-1, vim.fn.foldclosed(line + 3))

      t.feed("za")
      assert.are.same(-1, vim.fn.foldclosed(line + 10))

      vim.api.nvim_win_set_cursor(0, { line, 0 })
      t.feed("<tab>")
      assert.are.same(line, vim.fn.foldclosed(line))
      assert.are.same(line + 15, vim.fn.foldclosedend(line))

      t.feed("zo")
      assert.are.same(-1, vim.fn.foldclosed(line))
      t.feed("zc")
      assert.are.same(line, vim.fn.foldclosed(line))
    end)

    it("folds and unfolds a section", function()
      t.open(wc)
      local line = t.go("Changes (2)")

      t.feed("<tab>")
      assert.are.same(line, vim.fn.foldclosed(line))
      assert.are.same(line + 2, vim.fn.foldclosedend(line))
      -- The empty line below stays visible and keeps the folded section apart from the next one
      assert.are.same(-1, vim.fn.foldclosed(line + 3))
      assert.are.same("", t.lines()[line + 3])

      t.feed("<tab>")
      assert.are.same(-1, vim.fn.foldclosed(line))
    end)

    it("shows property changes and the content of unversioned files", function()
      wc:propset("svn:ignore", "*.o", "src")
      wc:write("new.txt", "first\nsecond\n")
      t.open(wc)

      local line = t.go("modified     src/ (properties)")
      t.feed("<tab>")
      assert.are.same({
        "modified     src/ (properties)",
        "Added: svn:ignore",
        "## -0,0 +1 ##",
        "+*.o",
      }, vim.list_slice(t.lines(), line, line + 3))

      line = t.go("new.txt")
      t.feed("<tab>")
      assert.are.same({
        "new.txt",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second",
      }, vim.list_slice(t.lines(), line, line + 3))
    end)

    it("sets the depth of a section with the number keys", function()
      t.open(wc)
      local section = t.find("Changes (2)")
      vim.api.nvim_win_set_cursor(0, { section + 1, 0 })

      -- 4: everything open
      t.feed("4")
      assert.is_true(t.has("@@ -1,5 +1,5 @@"))
      assert.is_true(t.has("+bye"))
      assert.are.same(-1, vim.fn.foldclosed(t.find("@@ -1,5 +1,5 @@") + 1))

      -- 3: the files open, their hunks closed
      vim.api.nvim_win_set_cursor(0, { section + 1, 0 })
      t.feed("3")
      local hunk = t.find("@@ -1,5 +1,5 @@")
      assert.are.same(hunk, vim.fn.foldclosed(hunk + 1))
      assert.are.same(-1, vim.fn.foldclosed(section + 1))

      -- 2: the files closed
      vim.api.nvim_win_set_cursor(0, { section + 1, 0 })
      t.feed("2")
      assert.are.same(section + 1, vim.fn.foldclosed(section + 1))
      assert.are.same(-1, vim.fn.foldclosed(section))

      -- 1: the section closed
      vim.api.nvim_win_set_cursor(0, { section + 1, 0 })
      t.feed("1")
      assert.are.same(section, vim.fn.foldclosed(section))
    end)

    it("keeps folds and cursor across a refresh", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")
      vim.api.nvim_win_set_cursor(0, { line + 4, 0 })

      wc:write("new.txt", "new\n")
      t.feed("<c-r>")
      t.wait_for_line("Unversioned files (1)")

      -- Everything moved down by the new section, the cursor with it
      local moved = t.find("modified     a.txt")
      assert.are.same(line + 3, moved)
      assert.is_true(t.has("+line 2 changed"))
      assert.are.same(-1, vim.fn.foldclosed(moved))
      assert.are.same("+line 2 changed", vim.api.nvim_get_current_line())
    end)

    it("keeps the cursor on what it is on when it is redrawn without being asked", function()
      local instance = t.open(wc)
      t.go("modified     b.txt")

      -- What the watcher does: the state changes, then the buffer is told to redraw
      wc:write("new.txt", "new\n")
      wc:refresh()
      instance:redraw()

      assert.is_true(t.has("Unversioned files (1)"))
      assert.are.same("modified     b.txt", (vim.api.nvim_get_current_line():gsub("%s+$", "")))
    end)

    it("leaves the cursor alone when it is above the sections", function()
      t.open(wc)
      local line = t.go("URL:      " .. wc.url)

      wc:write("new.txt", "new\n")
      t.feed("<c-r>")
      t.wait_for_line("Unversioned files (1)")

      assert.are.same(line, vim.fn.line("."))
    end)

    it("puts the cursor on the first section once the working copy is known", function()
      -- Opened before anything is known: there is no section to put the cursor on yet
      t.settle()
      wc:repo():reset()

      t.open(wc)

      assert.are.same("Changes (2)", vim.api.nvim_get_current_line())
    end)

    it("restores folds and cursor when it is opened again", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")
      vim.api.nvim_win_set_cursor(0, { line + 4, 0 })

      t.feed("q")
      t.wait(function()
        return vim.bo.filetype ~= "SvenStatus"
      end, "the status buffer to close")

      t.open(wc)
      t.wait(function()
        return vim.api.nvim_get_current_line() == "+line 2 changed"
      end, "the cursor to be back on the line it was on")
      assert.are.same(-1, vim.fn.foldclosed(t.find("modified     a.txt")))
    end)
  end)

  describe("navigation", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      wc:write("new.txt", "new\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist("sven-staged", "b.txt")
    end)

    it("skips the empty lines between sections when moving", function()
      t.open(wc)
      t.go("new.txt")

      t.feed("j")
      assert.are.same("Changes (1)", vim.api.nvim_get_current_line())

      t.feed("k")
      assert.are.same("new.txt", vim.api.nvim_get_current_line())

      -- With a count (1 to 4 set the depth of a section)
      t.feed("5j")
      assert.are.same("Staged changes (1)", vim.api.nvim_get_current_line())

      t.feed("5k")
      assert.are.same("new.txt", vim.api.nvim_get_current_line())

      -- Ending up on an empty line, it moves on
      t.feed("6j")
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+b%.txt"))
      t.feed("5k")
      assert.are.same("new.txt", vim.api.nvim_get_current_line())
    end)

    it("jumps from section to section", function()
      t.open(wc)
      t.go("Unversioned files (1)")

      t.feed("<c-n>")
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+a%.txt"))

      t.feed("<c-n>")
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+b%.txt"))

      t.feed("<c-p>")
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+a%.txt"))

      t.feed("<c-p>")
      assert.are.same("new.txt", vim.api.nvim_get_current_line())

      t.feed("<c-p>")
      assert.are.same(1, vim.fn.line("."))
    end)

    it("jumps from hunk header to hunk header", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")

      t.feed("}")
      assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())

      t.feed("}")
      assert.are.same("@@ -15,6 +15,6 @@", vim.api.nvim_get_current_line())

      t.feed("{")
      assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())

      t.feed("{")
      assert.are.same(line, vim.fn.line("."))
    end)

    it("walks through the diffs of the files, one at a time", function()
      wc:changelist("--remove", "b.txt")
      t.open(wc)

      t.go("modified     a.txt")
      t.feed("<tab>")
      assert.is_true(t.has("+line 2 changed"))

      -- Down: a.txt is folded again, the diff of b.txt is shown
      t.feed("<c-j>")
      local a = t.find("modified     a.txt")
      assert.are.same(a, vim.fn.foldclosed(a))
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+b%.txt"))
      assert.is_true(t.has("+bye"))
      assert.are.same(-1, vim.fn.foldclosed(vim.fn.line(".")))

      -- And back up
      t.feed("<c-k>")
      assert.is_truthy(vim.api.nvim_get_current_line():match("^modified%s+a%.txt"))
      assert.are.same(-1, vim.fn.foldclosed(vim.fn.line(".")))
      local b = t.find("modified     b.txt")
      assert.are.same(b, vim.fn.foldclosed(b))
    end)
  end)

  describe("commands", function()
    it("refreshes with <c-r>, the recent commits included", function()
      t.open(wc, { recent = true })
      assert.is_false(t.has("Changes (1)"))

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      local other = wc:checkout()
      other:replace("b.txt", "hello", "hello from elsewhere")
      other:commit("Change b.txt elsewhere")

      t.feed("<c-r>")

      t.wait_for_line("Changes (1)")
      t.wait_for_line("r3 Change b.txt elsewhere")
      assert.is_true(t.has("modified     a.txt"))
    end)

    it("explains that only http URLs can be opened in a browser", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      t.open(wc)
      t.go("modified     a.txt")

      local notifications = util.capture_notifications(function()
        t.feed("o")
      end)

      assert.are.same(1, #notifications)
      assert.are.same(
        "Only http(s) URLs can be opened in a browser, this one is:\n" .. wc.url .. "/a.txt",
        notifications[1].message
      )
      assert.are.same(vim.log.levels.WARN, notifications[1].level)
    end)

    it("opens the command history with $", function()
      t.open(wc)
      require("sven.lib.svn").cli.run { "info", "--show-item", "revision" }

      t.feed("$")
      assert.are.same("SvenCommandHistory", vim.bo.filetype)
      assert.is_truthy(table.concat(t.lines(), "\n"):match("svn info %-%-show%-item revision"))

      t.feed("q")
      t.wait(function()
        return vim.bo.filetype == "SvenStatus"
      end, "the status buffer to be focused again")
    end)

    it("closes with q", function()
      t.open(wc)

      t.feed("q")

      t.wait(function()
        return vim.bo.filetype ~= "SvenStatus"
      end, "the status buffer to close")
      assert.is_false(status.is_open())
    end)

    it("yanks the path of a file and the revision of a commit", function()
      wc:replace("src/main.c", "return 0", "return 1")
      wc:write("new.txt", "new\n")
      t.open(wc, { recent = true })

      t.go("modified     src/main.c")
      t.feed("Y")
      assert.are.same("src/main.c", vim.fn.getreg('"'))

      -- Inside its diff it is still the file
      t.feed("<tab>j")
      t.feed("Y")
      assert.are.same("src/main.c", vim.fn.getreg('"'))

      t.go("Head:     r2 ^/trunk Add the initial files")
      t.feed("Y")
      assert.are.same("r2", vim.fn.getreg('"'))

      t.go("URL:      " .. wc.url)
      t.feed("Y")
      assert.are.same(wc.url, vim.fn.getreg('"'))

      t.go("Recent commits")
      t.feed("<tab>j")
      t.feed("Y")
      assert.are.same("r2", vim.fn.getreg('"'))

      -- Every path of a selection
      t.go("new.txt")
      t.feed("V")
      t.go("modified     src/main.c")
      t.feed("Y")
      assert.are.same("new.txt\nsrc/main.c", vim.fn.getreg('"'))
    end)

    ---@return string[] The commands in the history that the user can see
    local function visible_history()
      local commands = {}
      for _, result in ipairs(require("sven.lib.svn").cli.history) do
        if not result.hidden then
          table.insert(commands, result.cmd)
        end
      end

      return commands
    end

    it("runs an svn command that is typed in, shows its output and refreshes", function()
      local instance = t.open(wc)
      local buf = instance.buffer.handle
      local prompts, restore = t.answer_input([[svn propset color "dark blue" a.txt]])

      t.feed("Q")

      -- The console takes the focus, the status buffer refreshes behind it
      t.wait(function()
        return vim.tbl_contains(t.lines(buf), "modified     a.txt (properties)")
      end, "the status buffer to show the property change")
      restore()

      assert.are.same({ "Run command in " .. wc.path }, prompts)
      assert.are.same("dark blue", vim.trim(wc:svn("propget", "color", "a.txt")))

      -- The console shows what the command printed, and stays
      local console = vim.fn.bufnr("SvenConsole")
      assert.is_true(console > 0)
      assert.is_true(#vim.fn.win_findbuf(console) > 0)

      local history = visible_history()
      assert.is_truthy(history[#history]:match("propset color dark blue a%.txt"))
    end)

    it("does nothing when the command prompt is cancelled", function()
      t.open(wc)
      local before = #visible_history()
      local _, restore = t.answer_input(nil)

      t.feed("Q")
      t.settle()
      restore()

      assert.are.same(before, #visible_history())
      assert.are.same("SvenStatus", vim.bo.filetype)
    end)

    it("splits a command line like a shell", function()
      local split = require("sven.buffers.status.actions").split_command

      assert.are.same({ "svn", "status" }, split("svn  status "))
      assert.are.same({ "commit", "-m", "two words" }, split([[commit -m "two words"]]))
      assert.are.same({ "commit", "-m", "it's" }, split([[commit -m "it's"]]))
      assert.are.same({ "add", "a file.txt", "" }, split([[add a\ file.txt '']]))
      assert.are.same({ 'say "hi"' }, split([["say \"hi\""]]))
    end)
  end)

  describe("opening what is under the cursor", function()
    before_each(function()
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      wc:write("newdir/x.txt", "x\n")
      wc:delete("b.txt")
    end)

    it("goes to a file with <cr>, closing the status buffer", function()
      t.open(wc)
      t.go("modified     a.txt")

      t.feed("<cr>")

      t.wait(function()
        return vim.api.nvim_buf_get_name(0) == wc:abs("a.txt")
      end, "a.txt to be opened")
      assert.is_false(status.is_open())
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))

      vim.cmd("bwipeout!")
    end)

    it("goes to the line of the file that the cursor is on in its diff", function()
      t.open(wc)
      local line = t.go("modified     a.txt")
      t.feed("<tab>")
      vim.api.nvim_win_set_cursor(0, { line + 6, 0 })
      assert.are.same("+line 18 changed", vim.api.nvim_get_current_line())

      t.feed("<cr>")

      t.wait(function()
        return vim.api.nvim_buf_get_name(0) == wc:abs("a.txt")
      end, "a.txt to be opened")
      assert.are.same(18, vim.fn.line("."))
      assert.are.same("line 18 changed", vim.api.nvim_get_current_line())

      vim.cmd("bwipeout!")
    end)

    it("opens a file in a split, a vertical split or a tab", function()
      t.open(wc)

      t.go("modified     a.txt")
      t.feed("<c-x>")
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same(3, #vim.api.nvim_tabpage_list_wins(0))
      vim.cmd("close")

      status.instance(wc.path):focus()
      t.go("modified     a.txt")
      t.feed("<c-v>")
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same(3, #vim.api.nvim_tabpage_list_wins(0))
      vim.cmd("close")

      status.instance(wc.path):focus()
      t.go("modified     a.txt")
      t.feed("<c-t>")
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same(2, #vim.api.nvim_list_tabpages())
      vim.cmd("tabclose")

      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("a.txt")))
    end)

    it("peeks at a file, staying in the status buffer", function()
      t.open(wc)
      t.go("modified     a.txt")

      t.feed("<s-cr>")

      assert.are.same("SvenStatus", vim.bo.filetype)
      assert.are.same(3, #vim.api.nvim_tabpage_list_wins(0))
      assert.is_true(#vim.fn.win_findbuf(vim.fn.bufnr(wc:abs("a.txt"))) > 0)

      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("a.txt")))
    end)

    it("opens an unversioned directory without complaining", function()
      t.open(wc)
      t.go("newdir/")
      vim.v.errmsg = ""

      local notifications = util.capture_notifications(function()
        t.feed("<cr>")
        t.wait(function()
          return vim.bo.filetype ~= "SvenStatus"
        end, "the status buffer to close")
      end)

      assert.are.same({}, notifications)
      assert.are.same("", vim.v.errmsg)

      -- The directory is about to be removed by the spec
      vim.cmd("silent! bwipeout!")
    end)

    it("says that a deleted file cannot be opened", function()
      t.open(wc)
      t.go("deleted      b.txt")

      local notifications = util.capture_notifications(function()
        t.feed("<cr>")
      end)

      assert.are.same(1, #notifications)
      assert.are.same("b.txt is deleted: there is nothing to open", notifications[1].message)
      assert.are.same("SvenStatus", vim.bo.filetype)
    end)

    describe("a recent commit", function()
      local calls
      local view_is_open

      before_each(function()
        calls = {}
        view_is_open = false

        local view = { instance = nil }
        function view.new(revision, filter)
          table.insert(calls, { "new", revision, filter })
          return {
            open = function(_, kind)
              table.insert(calls, { "open", revision, kind })
            end,
          }
        end
        function view.open_or_scroll_down(revision)
          table.insert(calls, { "open_or_scroll_down", revision })
        end
        function view.open_or_scroll_up(revision)
          table.insert(calls, { "open_or_scroll_up", revision })
        end
        function view.is_open()
          return view_is_open
        end

        t.stub_module("sven.buffers.revision_view", view)
      end)

      local function go_to_newest_commit()
        t.go("Recent commits")
        t.feed("<tab>")
        t.go("r2 Add the initial files")
      end

      it("is shown in the revision view with <cr>", function()
        t.open(wc, { recent = true })
        go_to_newest_commit()

        t.feed("<cr>")

        assert.are.same({ { "new", "2" }, { "open", "2" } }, calls)
        -- The status buffer stays
        assert.are.same("SvenStatus", vim.bo.filetype)
      end)

      it("is opened or scrolled with ]c and [c", function()
        t.open(wc, { recent = true })
        go_to_newest_commit()

        t.feed("]c")
        t.feed("[c")

        assert.are.same({ { "open_or_scroll_down", "2" }, { "open_or_scroll_up", "2" } }, calls)
      end)

      it("is peeked at with <s-cr>", function()
        t.open(wc, { recent = true })
        go_to_newest_commit()

        t.feed("<s-cr>")

        assert.are.same({ { "new", "2" }, { "open", "2" } }, calls)
        assert.are.same("SvenStatus", vim.bo.filetype)
      end)

      it("does nothing on a file with ]c", function()
        t.open(wc, { recent = true })
        t.go("modified     a.txt")

        t.feed("]c")

        assert.are.same({}, calls)
      end)

      it("follows the cursor in the revision view while that is open", function()
        t.open(wc, { recent = true })
        go_to_newest_commit()

        -- Closed: the cursor just moves
        t.feed("<c-j>")
        assert.are.same("r1 Create the layout", vim.api.nvim_get_current_line())
        assert.are.same({}, calls)

        view_is_open = true
        t.feed("<c-k>")
        assert.are.same("r2 Add the initial files", vim.api.nvim_get_current_line())
        assert.are.same({ { "new", "2" }, { "open", "2" } }, calls)
        assert.are.same("SvenStatus", vim.bo.filetype)

        -- With the revision view open, q closes that first
        view_is_open = false
      end)

      it("results in a notification when the revision view is missing", function()
        t.stub_module("sven.buffers.revision_view", function()
          error("module 'sven.buffers.revision_view' not found")
        end)
        t.open(wc, { recent = true })
        go_to_newest_commit()

        local notifications = util.capture_notifications(function()
          t.feed("<cr>")
        end)

        assert.are.same(1, #notifications)
        assert.are.same("The revision view is not available", notifications[1].message)
        assert.are.same(vim.log.levels.WARN, notifications[1].level)
      end)

      it("results in a notification when the revision view is broken", function()
        local view = {
          new = function()
            error("the revision view is broken")
          end,
        }
        t.stub_module("sven.buffers.revision_view", view)
        t.open(wc, { recent = true })
        go_to_newest_commit()

        local notifications = util.capture_notifications(function()
          t.feed("<cr>")
        end)

        assert.are.same(1, #notifications)
        assert.is_truthy(notifications[1].message:match("The revision view failed"))
        assert.is_truthy(notifications[1].message:match("the revision view is broken"))
        assert.are.same(vim.log.levels.ERROR, notifications[1].level)
      end)
    end)

    describe("blame", function()
      local blamed

      before_each(function()
        blamed = {}
        t.stub_module("sven.buffers.blame_view", {
          open = function(path, opts)
            table.insert(blamed, { path, opts })
          end,
        })
      end)

      it("blames the file under the cursor with B", function()
        t.open(wc)
        t.go("modified     a.txt")

        t.feed("B")

        t.wait(function()
          return #blamed == 1
        end, "the blame view to be opened")
        assert.are.same({ { wc:abs("a.txt") } }, blamed)
      end)

      it("explains what cannot be blamed", function()
        wc:write("new.txt", "new\n")
        t.open(wc)

        t.go("new.txt")
        local notifications = util.capture_notifications(function()
          t.feed("B")
        end)
        assert.are.same("new.txt is unversioned: it has no history to blame yet", notifications[1].message)

        t.go("newdir/")
        notifications = util.capture_notifications(function()
          t.feed("B")
        end)
        assert.are.same("newdir/ is a directory: only files can be blamed", notifications[1].message)

        t.go("Changes (2)")
        notifications = util.capture_notifications(function()
          t.feed("B")
        end)
        assert.are.same("There is no file under the cursor to blame", notifications[1].message)

        assert.are.same({}, blamed)
        assert.are.same("SvenStatus", vim.bo.filetype)
      end)
    end)
  end)

  describe("popups", function()
    local created

    before_each(function()
      created = {}

      for _, name in ipairs { "commit", "log", "diff", "update", "resolve", "help" } do
        t.stub_module("sven.popups." .. name, {
          create = function(env)
            table.insert(created, { name = name, env = env })
          end,
        })
      end

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:write("new.txt", "new\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("review", "src/main.c")
    end)

    it("opens every popup through the registry, with its key", function()
      t.open(wc)
      t.go("modified     a.txt")

      for _, key in ipairs { "c", "l", "d", "F", "r", "?" } do
        t.feed(key)
      end

      assert.are.same(
        { "commit", "log", "diff", "update", "resolve", "help" },
        vim.tbl_map(function(popup)
          return popup.name
        end, created)
      )
    end)

    it("tells a popup what the cursor is on", function()
      t.open(wc, { recent = true })

      t.go("modified     a.txt")
      t.feed("c")
      local env = created[1].env
      assert.are.same("a.txt", env.item.name)
      assert.are.same("modified", env.item.status)
      assert.are.same({ name = "changes" }, env.section)
      assert.are.same({ "a.txt" }, env.paths)
      assert.is_nil(env.revision)

      -- Inside the diff of a file it is still that file
      t.feed("<tab>jj")
      t.feed("c")
      assert.are.same("a.txt", created[2].env.item.name)
      assert.are.same({ "a.txt" }, created[2].env.paths)

      -- A section header stands for everything in the section
      t.go("Changes (2)")
      t.feed("c")
      env = created[3].env
      assert.is_nil(env.item)
      assert.are.same({ name = "changes" }, env.section)
      assert.are.same({ "a.txt", "b.txt" }, env.paths)

      t.go("modified     src/main.c")
      t.feed("d")
      assert.are.same({ name = "changelist:review" }, created[4].env.section)

      t.go("new.txt")
      t.feed("d")
      assert.are.same({ name = "unversioned" }, created[5].env.section)
      assert.are.same("unversioned", created[5].env.item.status)

      t.go("Recent commits")
      t.feed("<tab>j")
      t.feed("l")
      env = created[6].env
      assert.are.same(2, env.revision)
      assert.are.same({ name = "recent" }, env.section)
      assert.is_nil(env.item)
      assert.are.same({}, env.paths)

      -- Nothing in particular
      t.go("URL:      " .. wc.url)
      t.feed("F")
      assert.are.same({ paths = {} }, created[7].env)
    end)

    it("tells a popup what is selected in visual mode", function()
      t.open(wc)

      t.go("new.txt")
      t.feed("V")
      t.go("modified     b.txt")
      t.feed("c")

      assert.are.same("commit", created[1].name)
      assert.are.same({ "new.txt", "a.txt", "b.txt" }, created[1].env.paths)
      assert.is_nil(created[1].env.item)
      assert.is_nil(created[1].env.section)
      assert.are.same("n", vim.fn.mode())

      for _, key in ipairs { "l", "d", "F", "r", "?" } do
        t.go("modified     a.txt")
        t.feed("V" .. key)
      end

      assert.are.same(
        { "commit", "log", "diff", "update", "resolve", "help" },
        vim.tbl_map(function(popup)
          return popup.name
        end, created)
      )
      assert.are.same({ "a.txt" }, created[6].env.paths)
    end)

    it("says so when a popup cannot be loaded", function()
      t.stub_module("sven.popups.diff", function()
        error("this popup is broken")
      end)
      t.open(wc)

      local notifications = util.capture_notifications(function()
        t.feed("d")
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("Failed to load popup"))
    end)
  end)

  describe("refreshing on its own", function()
    for _, event in ipairs {
      "SvenCommitComplete",
      "SvenUpdateComplete",
      "SvenResolveComplete",
      "SvenRevertComplete",
    } do
      it("refreshes on User " .. event, function()
        t.open(wc)
        assert.is_false(t.has("Changes (1)"))

        wc:replace("a.txt", "line 2\n", "line 2 changed\n")
        vim.api.nvim_exec_autocmds("User", { pattern = event, modeline = false })

        t.wait_for_line("Changes (1)")
        assert.is_true(t.has("modified     a.txt"))
      end)
    end

    it("refreshes when it is asked to from elsewhere", function()
      t.open(wc)
      vim.cmd("wincmd p")

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      status.instance(wc.path):dispatch_refresh(nil, "spec")

      status.instance(wc.path):focus()
      t.wait_for_line("Changes (1)")
    end)

    it("starts over on a reset", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      local instance = t.open(wc, { recent = true })

      instance:dispatch_reset()

      t.wait(function()
        return t.has("Changes (1)") and t.has("r2 Add the initial files")
      end, "the state to be read again")
    end)

    it("redraws when the watcher sees svn change the working copy", function()
      harness.setup { filewatcher = { enabled = true } }
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      t.open(wc)
      assert.is_true(t.has("Changes (1)"))

      -- Staged behind the back of Neovim
      wc:changelist("sven-staged", "a.txt")

      t.wait_for_line("Staged changes (1)", 8000)
      assert.is_false(t.has("Changes (1)"))
    end)

    it("refreshes when a file of the working copy is written", function()
      -- The window the file is written in has another working directory than the status buffer
      t.open(wc)

      vim.cmd("wincmd p")
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("b.txt")))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written from a buffer, which makes it longer" })
      vim.cmd("silent write")
      vim.cmd("wincmd p")

      t.wait(function()
        return vim.bo.filetype == "SvenStatus" and t.has("modified     b.txt")
      end, "the written file to be listed")

      -- And on every write after the first one
      vim.cmd("wincmd p")
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("a.txt")))
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line 1, written from a buffer" })
      vim.cmd("silent write")
      vim.cmd("wincmd p")

      t.wait(function()
        return vim.bo.filetype == "SvenStatus" and t.has("Changes (2)")
      end, "the second written file to be listed")

      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("a.txt")))
      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("b.txt")))
    end)

    it("refreshes when a file is written in another tab", function()
      wc:replace("b.txt", "hello", "bye")
      local instance = t.open(wc, { kind = "tab" })
      local line = t.go("modified     b.txt")
      t.feed("<tab>")
      assert.are.same("+bye", t.lines()[line + 3])

      vim.cmd("tabprevious")
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("b.txt")))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written in another tab" })
      vim.cmd("silent write")

      -- The diff that is unfolded over there is the one of what was written
      t.wait(function()
        return t.lines(instance.buffer.handle)[line + 3] == "+written in another tab"
      end, "the diff of the written file to be shown")

      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("b.txt")))
    end)

    it("does not scroll when it refreshes while another window is focused", function()
      wc:replace("b.txt", "hello", "bye")
      local instance = t.open(wc)
      local line = t.go("modified     b.txt")
      t.feed("<tab>")
      local status_window = vim.api.nvim_get_current_win()
      assert.are.same(1, vim.fn.line("w0", status_window))

      -- A window that is scrolled down, next to the status buffer
      vim.cmd("wincmd p")
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("a.txt")))
      vim.cmd("resize 5")
      vim.cmd("normal! 15zt")
      assert.are.same(15, vim.fn.line("w0"))

      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line 1 changed" })
      vim.cmd("silent write")

      t.wait(function()
        return vim.tbl_contains(t.lines(instance.buffer.handle), "modified     a.txt")
      end, "the written file to be listed")
      t.settle()

      assert.are.same(1, vim.fn.line("w0", status_window))
      assert.are.same(line + 1, vim.api.nvim_win_get_cursor(status_window)[1])

      vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(wc:abs("a.txt")))
    end)

    it("does not keep a stale diff when a partial refresh overtakes a full one", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      t.open(wc)

      -- Both diffs are loaded, and cached
      t.go("Changes (2)")
      t.feed("j4")
      assert.is_true(t.has("+bye"))

      -- Changed behind the back of sven: still "modified", but differently
      wc:write("b.txt", "changed again\n")

      local repo = wc:repo()
      local done = false
      repo:refresh { source = "full" }
      repo:refresh {
        source = "partial",
        partial = { update_diffs = { "*:a.txt" } },
        callback = function()
          done = true
        end,
      }
      t.wait(function()
        return done
      end, "the refresh to finish")

      local diff = require("sven.lib.svn").status.find("b.txt").diff
      assert.are.same({ "@@ -1 +1 @@", "-hello", "+changed again" }, diff.lines)
    end)

    it("leaves the status buffer alone when a file outside of the working copy is written", function()
      t.open(wc)
      local refreshes = 0
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "SvenStatusRefreshed",
        callback = function()
          refreshes = refreshes + 1
        end,
      })

      local file = vim.fn.tempname()
      vim.cmd("wincmd p")
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "elsewhere" })
      vim.cmd("silent write")
      t.settle()

      vim.api.nvim_del_autocmd(id)
      vim.cmd("silent! bwipeout!")
      vim.fn.delete(file)

      assert.are.same(0, refreshes)
    end)

    it("does not fail when a refresh finishes after it was closed", function()
      local instance = t.open(wc)
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      vim.v.errmsg = ""

      instance:dispatch_refresh(nil, "spec")
      instance:close()
      t.settle()

      assert.is_nil(instance.buffer)
      assert.are.same("", vim.v.errmsg)
    end)
  end)
end)
