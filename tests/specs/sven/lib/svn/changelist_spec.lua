local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local changelist = require("sven.lib.svn.changelist")

local STAGED = "sven-staged"

---@param items SvenStatusItem[]
---@return string[]
local function names(items)
  return vim.tbl_map(function(item)
    return item.name
  end, items)
end

describe("lib.svn.changelist", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  describe("#stage", function()
    it("stages a modified file", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      assert.is_true(changelist.stage { "a.txt" })

      assert.are.same({ "a.txt" }, wc:members(STAGED))

      local state = wc:refresh()
      assert.are.same({ "a.txt" }, names(state.staged.items))
      assert.are.same({ "b.txt" }, names(state.changes.items))
    end)

    it("adds an unversioned file before staging it", function()
      wc:write("new.txt", "new\n")

      assert.is_true(changelist.stage { "new.txt" })

      assert.are.same("A", wc:status_of("new.txt"))
      assert.are.same({ "new.txt" }, wc:members(STAGED))
    end)

    it("adds an unversioned directory recursively", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")

      assert.is_true(changelist.stage { "newdir" })

      assert.are.same("A", wc:status_of("newdir"))
      assert.are.same("A", wc:status_of("newdir/deep"))
      assert.are.same({ "newdir/deep/y.txt", "newdir/x.txt" }, wc:members(STAGED))

      local state = wc:refresh()
      assert.are.same(
        { "newdir", "newdir/deep", "newdir/deep/y.txt", "newdir/x.txt" },
        names(state.staged.items)
      )
      assert.are.same({}, names(state.unversioned.items))
      assert.are.same({}, names(state.changes.items))
    end)

    it("stages a file inside an unversioned directory, adding its parents", function()
      wc:write("newdir/deep/y.txt", "y\n")
      wc:write("newdir/x.txt", "x\n")

      assert.is_true(changelist.stage { "newdir/deep/y.txt" })

      assert.are.same("A", wc:status_of("newdir"))
      assert.are.same("A", wc:status_of("newdir/deep"))
      assert.are.same("?", wc:status_of("newdir/x.txt"))
      assert.are.same({ "newdir/deep/y.txt" }, wc:members(STAGED))
    end)

    it("schedules a missing file for deletion before staging it", function()
      wc:remove("b.txt")
      assert.are.same("!", wc:status_of("b.txt"))

      assert.is_true(changelist.stage { "b.txt" })

      assert.are.same("D", wc:status_of("b.txt"))
      assert.are.same({ "b.txt" }, wc:members(STAGED))
    end)

    it("schedules a missing directory for deletion and stages everything in it", function()
      wc:remove("src")

      assert.is_true(changelist.stage { "src" })

      assert.are.same("D", wc:status_of("src"))
      assert.are.same({ "src/main.c", "src/sub/util.c" }, wc:members(STAGED))

      local state = wc:refresh()
      assert.are.same({ "src", "src/main.c", "src/sub/util.c" }, names(state.staged.items))
    end)

    it("stages everything inside a deleted directory", function()
      wc:delete("src")

      assert.is_true(changelist.stage { "src" })

      assert.are.same({ "src/main.c", "src/sub/util.c" }, wc:members(STAGED))
    end)

    it("stages only the changed files of a directory", function()
      wc:replace("src/main.c", "return 0", "return 1")
      wc:write("src/new.c", "x\n")

      assert.is_true(changelist.stage { "src" })

      -- src/sub/util.c has no changes and must not become a member
      assert.are.same({ "src/main.c", "src/new.c" }, wc:members(STAGED))
      assert.are.same("A", wc:status_of("src/new.c"))
    end)

    it("stages a deleted and an added file", function()
      wc:delete("b.txt")
      wc:write("added.txt", "added\n")
      wc:add("added.txt")

      assert.is_true(changelist.stage { "b.txt", "added.txt" })

      assert.are.same({ "added.txt", "b.txt" }, wc:members(STAGED))
    end)

    it("moves a file out of another changelist", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:changelist("other", "a.txt")

      assert.is_true(changelist.stage { "a.txt" })

      assert.are.same({ "a.txt" }, wc:members(STAGED))
      assert.are.same({}, wc:members("other"))
    end)

    it("accepts absolute paths", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")

      assert.is_true(changelist.stage { wc:abs("a.txt"), wc:abs("new.txt") })

      assert.are.same({ "a.txt", "new.txt" }, wc:members(STAGED))
    end)

    it("handles file names with spaces, non-ASCII characters and an @", function()
      wc:write("with space.txt", "x\n")
      wc:write("ümlaut.txt", "x\n")
      wc:write("icon@2x.txt", "x\n")

      assert.is_true(changelist.stage { "with space.txt", "ümlaut.txt", "icon@2x.txt" })

      assert.are.same({ "icon@2x.txt", "with space.txt", "ümlaut.txt" }, wc:members(STAGED))
    end)

    it("ignores paths without changes", function()
      assert.is_true(changelist.stage { "a.txt", "src" })

      assert.are.same({}, wc:members(STAGED))
    end)

    it("does not add the files svn left next to a conflicted file", function()
      local other = wc:checkout()
      other:replace("src/main.c", "return 0", "return 2")
      other:commit("Return 2")

      wc:replace("src/main.c", "return 0", "return 1")
      wc:write("src/new.c", "x\n")
      wc:update()
      assert.is_true(wc:exists("src/main.c.mine"))

      assert.is_true(changelist.stage { "src" })

      assert.are.same("?", wc:status_of("src/main.c.mine"))
      assert.are.same("A", wc:status_of("src/new.c"))
    end)

    it("tells the user that a directory itself cannot be staged", function()
      wc:mkdir("empty")
      wc:add("empty")

      local notifications = util.capture_notifications(function()
        assert.is_true(changelist.stage { "empty" })
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("Nothing to stage"))
      assert.are.same({}, wc:members(STAGED))
    end)
  end)

  describe("#unstage", function()
    it("unstages a file", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist(STAGED, "a.txt", "b.txt")

      assert.is_true(changelist.unstage { "a.txt" })

      assert.are.same({ "b.txt" }, wc:members(STAGED))
    end)

    it("does not undo the addition of a file", function()
      wc:write("new.txt", "new\n")
      changelist.stage { "new.txt" }

      assert.is_true(changelist.unstage { "new.txt" })

      assert.are.same("A", wc:status_of("new.txt"))
      assert.are.same({}, wc:members(STAGED))

      local state = wc:refresh()
      assert.are.same({ "new.txt" }, names(state.changes.items))
    end)

    it("unstages everything below a directory", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      changelist.stage { "newdir", "a.txt" }

      assert.is_true(changelist.unstage { "newdir" })

      assert.are.same({ "a.txt" }, wc:members(STAGED))

      local state = wc:refresh()
      assert.are.same({ "a.txt" }, names(state.staged.items))
      assert.are.same(
        { "newdir", "newdir/deep", "newdir/deep/y.txt", "newdir/x.txt" },
        names(state.changes.items)
      )
    end)

    it("leaves members of other changelists alone", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:changelist("other", "a.txt")

      assert.is_true(changelist.unstage { "a.txt" })

      assert.are.same({ "a.txt" }, wc:members("other"))
    end)
  end)

  describe("#stage_all", function()
    it("stages versioned changes and unversioned paths", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:delete("b.txt")
      wc:remove("src/main.c")
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      wc:write("kept.txt", "kept\n")
      wc:add("kept.txt")
      wc:changelist("other", "kept.txt")

      assert.is_true(changelist.stage_all())

      assert.are.same({ "a.txt", "b.txt", "new.txt", "newdir/x.txt", "src/main.c" }, wc:members(STAGED))
      assert.are.same({ "kept.txt" }, wc:members("other"))

      local state = wc:refresh()
      assert.are.same({}, names(state.changes.items))
      assert.are.same({}, names(state.unversioned.items))
    end)

    it("does nothing in a clean working copy", function()
      assert.is_true(changelist.stage_all())
      assert.are.same({}, wc:members(STAGED))
    end)
  end)

  describe("#stage_changes", function()
    it("stages versioned changes only", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:delete("b.txt")
      wc:write("new.txt", "new\n")

      assert.is_true(changelist.stage_changes())

      assert.are.same({ "a.txt", "b.txt" }, wc:members(STAGED))
      assert.are.same("?", wc:status_of("new.txt"))
    end)
  end)

  describe("#unstage_all", function()
    it("empties the staging changelist", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist(STAGED, "a.txt", "src/main.c")
      wc:changelist("other", "b.txt")

      assert.is_true(changelist.unstage_all())

      assert.are.same({}, wc:members(STAGED))
      assert.are.same({ "b.txt" }, wc:members("other"))
    end)
  end)

  describe("#add and #remove", function()
    it("manage any changelist", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      assert.is_true(changelist.add("review", { "a.txt", "b.txt" }))
      assert.are.same({ "a.txt", "b.txt" }, wc:members("review"))

      assert.is_true(changelist.remove { "a.txt" })
      assert.are.same({ "b.txt" }, wc:members("review"))
    end)
  end)
end)
