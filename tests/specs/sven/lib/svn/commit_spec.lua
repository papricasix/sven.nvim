local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local commit = require("sven.lib.svn.commit")
local changelist = require("sven.lib.svn.changelist")

local STAGED = "sven-staged"

---@param items SvenStatusItem[]
---@return string[]
local function names(items)
  return vim.tbl_map(function(item)
    return item.name
  end, items)
end

describe("lib.svn.commit", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  describe("#staged", function()
    it("commits the staged files and nothing else", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGED, "a.txt")
      wc:changelist("other", "src/main.c")

      local revision, err = commit.staged("Change line 2")

      assert.is_nil(err)
      assert.are.same(3, revision)
      assert.are.same(3, wc:head())
      assert.are.same("Change line 2", wc:log_message(3))
      assert.are.same({ "M /trunk/a.txt" }, wc:changed_paths(3))

      -- Committed files leave the changelist, the rest is untouched
      assert.are.same({}, wc:members(STAGED))
      assert.are.same({ "src/main.c" }, wc:members("other"))
      assert.are.same("M", wc:status_of("b.txt"))
      assert.are.same("", wc:status_of("a.txt"))
    end)

    it("passes the message unchanged", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:changelist(STAGED, "a.txt")

      local message = table.concat({
        "Subject with \"quotes\", 'apostrophes' and ümlauts",
        "",
        "- a list item",
        "--not-an-option",
        "#123 is not a comment",
      }, "\n")
      local revision = commit.staged(message)

      assert.are.same(message, wc:log_message(revision))
    end)

    it("commits staged files inside a newly added directory", function()
      -- Changelists hold files only, so `svn commit --changelist` leaves the directories out
      -- and fails: the parents of the files are not in the repository yet.
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")
      wc:write("newdir/deep/unstaged.txt", "not yet\n")
      changelist.stage { "newdir" }
      changelist.unstage { "newdir/deep/unstaged.txt" }

      local revision, err = commit.staged("Add newdir")

      assert.is_nil(err)
      assert.are.same(3, revision)
      assert.are.same({
        "A /trunk/newdir",
        "A /trunk/newdir/deep",
        "A /trunk/newdir/deep/y.txt",
        "A /trunk/newdir/x.txt",
      }, wc:changed_paths(3))

      -- The file that was not staged is still waiting
      assert.are.same("A", wc:status_of("newdir/deep/unstaged.txt"))
      assert.are.same("", wc:status_of("newdir"))
    end)

    it("commits a staged file next to files that are only added", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/z.txt", "z\n")
      wc:add("newdir")
      wc:changelist(STAGED, "newdir/x.txt")

      local revision = commit.staged("Add newdir/x.txt")

      assert.are.same({ "A /trunk/newdir", "A /trunk/newdir/x.txt" }, wc:changed_paths(revision))
      assert.are.same("A", wc:status_of("newdir/z.txt"))
    end)

    it("commits a directory deletion once everything in it is staged", function()
      wc:delete("src")
      changelist.stage { "src" }

      local revision, err = commit.staged("Remove src")

      assert.is_nil(err)
      assert.are.same(3, revision)
      assert.are.same({ "D /trunk/src" }, wc:changed_paths(3))
      assert.are.same({}, wc:status())
    end)

    it("refuses to commit part of a deleted directory", function()
      wc:delete("src")
      wc:changelist(STAGED, "src/main.c")

      local revision, err
      local notifications = util.capture_notifications(function()
        revision, err = commit.staged("Remove src/main.c")
      end)

      assert.is_nil(revision)
      assert.is_truthy(err:match("scheduled for deletion"))
      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("Cannot commit"))
      assert.are.same(2, wc:head())
    end)

    it("commits staged deletions and missing files", function()
      wc:delete("b.txt")
      wc:remove("noeol.txt")
      changelist.stage { "b.txt", "noeol.txt" }

      local revision = commit.staged("Remove two files")

      assert.are.same({ "D /trunk/b.txt", "D /trunk/noeol.txt" }, wc:changed_paths(revision))
    end)

    it("refuses when nothing is staged", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      local revision, err
      local notifications = util.capture_notifications(function()
        revision, err = commit.staged("Nothing")
      end)

      assert.is_nil(revision)
      assert.are.same("Nothing is staged", err)
      assert.are.same(1, #notifications)
      assert.are.same(2, wc:head())
    end)

    it("does not commit a staged file that is in conflict", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist(STAGED, "a.txt", "b.txt")
      wc:update()

      local revision = commit.staged("Change b.txt")

      assert.are.same({ "M /trunk/b.txt" }, wc:changed_paths(revision))
      assert.are.same("C", wc:status_of("a.txt"))
    end)

    it("reports a failing commit", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      -- Out of date: the repository has a newer a.txt
      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:changelist(STAGED, "a.txt")

      local revision, err
      local notifications = util.capture_notifications(function()
        revision, err = commit.staged("Change line 5 too")
      end)

      assert.is_nil(revision)
      assert.is_truthy(err:match("E160028") or err:match("out of date"))
      assert.are.same(1, #notifications)
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
      assert.are.same({ "a.txt" }, wc:members(STAGED))
    end)

    it("handles more targets than fit on a command line comfortably", function()
      local paths = {}
      for i = 1, 150 do
        local path = ("many/file with space %03d.txt"):format(i)
        wc:write(path, "content\n")
        table.insert(paths, path)
      end
      wc:write("many/icon@2x.txt", "content\n")
      changelist.stage { "many" }

      local revision, err = commit.staged("Add many files")

      assert.is_nil(err)
      assert.are.same(152, #wc:changed_paths(revision))
      assert.are.same({}, wc:status())
    end)
  end)

  describe("#staged_targets", function()
    it("lists the staged files and the added directories above them", function()
      wc:write("newdir/deep/y.txt", "y\n")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      changelist.stage { "newdir", "a.txt" }

      assert.are.same({ "a.txt", "newdir", "newdir/deep", "newdir/deep/y.txt" }, commit.staged_targets())
    end)

    it("names the deleted directory instead of the files in it", function()
      wc:delete("src")
      changelist.stage { "src" }

      assert.are.same({ "src" }, commit.staged_targets())
    end)
  end)

  describe("#all", function()
    it("commits every change, whatever changelist it is in", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:write("added/x.txt", "x\n")
      wc:add("added")
      wc:write("unversioned.txt", "x\n")
      wc:changelist(STAGED, "a.txt")
      wc:changelist("other", "b.txt")

      local revision, err = commit.all("Commit everything")

      assert.is_nil(err)
      assert.are.same(3, revision)
      assert.are.same({
        "A /trunk/added",
        "A /trunk/added/x.txt",
        "M /trunk/a.txt",
        "M /trunk/b.txt",
        "M /trunk/src/main.c",
      }, wc:changed_paths(3))
      assert.are.same({ "?       unversioned.txt" }, wc:status())
    end)

    it("reports that there was nothing to commit", function()
      local revision, err = commit.all("Nothing")

      assert.is_nil(revision)
      assert.are.same("Nothing was committed", err)
    end)
  end)

  describe("#paths", function()
    it("commits the changes of the given paths", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:replace("src/sub/util.c", "a + b", "b + a")

      local revision, err = commit.paths({ "a.txt", "src" }, "Commit some paths")

      assert.is_nil(err)
      assert.are.same(
        { "M /trunk/a.txt", "M /trunk/src/main.c", "M /trunk/src/sub/util.c" },
        wc:changed_paths(revision)
      )
      assert.are.same("M", wc:status_of("b.txt"))
    end)

    it("includes added parent directories", function()
      wc:write("newdir/deep/y.txt", "y\n")
      wc:write("newdir/x.txt", "x\n")
      wc:add("newdir")

      local revision = commit.paths({ "newdir/deep/y.txt" }, "Add one file")

      assert.are.same(
        { "A /trunk/newdir", "A /trunk/newdir/deep", "A /trunk/newdir/deep/y.txt" },
        wc:changed_paths(revision)
      )
      assert.are.same("A", wc:status_of("newdir/x.txt"))
    end)

    it("commits an added empty directory and a property change of a directory", function()
      wc:mkdir("empty")
      wc:add("empty")
      wc:propset("color", "red", "docs")

      local revision = commit.paths({ "empty", "docs" }, "Directory changes")

      assert.are.same({ "A /trunk/empty", "M /trunk/docs" }, wc:changed_paths(revision))
    end)

    it("commits a deleted directory", function()
      wc:delete("src")

      local revision = commit.paths({ "src" }, "Remove src")

      assert.are.same({ "D /trunk/src" }, wc:changed_paths(revision))
    end)

    it("accepts absolute paths", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      local revision = commit.paths({ wc:abs("a.txt") }, "Commit a.txt")

      assert.are.same({ "M /trunk/a.txt" }, wc:changed_paths(revision))
    end)

    it("refuses paths without changes", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      local revision, err
      util.capture_notifications(function()
        revision, err = commit.paths({ "b.txt" }, "Nothing")
      end)

      assert.is_nil(revision)
      assert.is_truthy(err:match("no changes"))
      assert.are.same(2, wc:head())
    end)

    it("refuses conflicted paths", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:update()

      local revision, err
      util.capture_notifications(function()
        revision, err = commit.paths({ "a.txt" }, "Conflicted")
      end)

      assert.is_nil(revision)
      assert.is_truthy(err:match("conflict"))
    end)
  end)

  it("invalidates the cached recent log entries", function()
    wc:refresh()
    local before = wc:wait_for_recent()
    assert.are.same(2, before[1].revision)

    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:changelist(STAGED, "a.txt")
    commit.staged("Change line 2")

    wc:refresh()
    local after = wc:wait_for_recent()
    assert.are.same(3, after[1].revision)
    assert.are.same("Change line 2", after[1].subject)
    assert.are.same({}, names(wc:repo().state.staged.items))
  end)
end)
