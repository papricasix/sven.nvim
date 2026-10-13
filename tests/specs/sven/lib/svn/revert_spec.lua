local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local revert = require("sven.lib.svn.revert")
local changelist = require("sven.lib.svn.changelist")

local STAGED = "sven-staged"

---@param state SvenRepoState
---@param name string
---@return SvenStatusItem
local function find(state, name)
  local found
  require("sven.lib.svn.status").each(state, function(item)
    if item.name == name then
      found = item
    end
  end)

  return assert(found, "No item named " .. name)
end

describe("lib.svn.revert", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  describe("#files", function()
    it("reverts a modified file", function()
      local original = wc:read("a.txt")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      assert.is_true(revert.files { "a.txt" })

      assert.are.same(original, wc:read("a.txt"))
      assert.are.same({ "M       b.txt" }, wc:status())
    end)

    it("restores deleted and missing files", function()
      wc:delete("b.txt")
      wc:remove("noeol.txt")

      assert.is_true(revert.files { "b.txt", "noeol.txt" })

      assert.are.same("hello\n", wc:read("b.txt"))
      assert.are.same("no newline at the end", wc:read("noeol.txt"))
      assert.are.same({}, wc:status())
    end)

    it("unschedules an added file and keeps it on disk", function()
      wc:write("added.txt", "added\n")
      wc:add("added.txt")

      assert.is_true(revert.files { "added.txt" })

      assert.are.same({ "?       added.txt" }, wc:status())
      assert.are.same("added\n", wc:read("added.txt"))
    end)

    it("reverts a directory recursively", function()
      wc:replace("src/main.c", "return 0", "return 1")
      wc:replace("src/sub/util.c", "a + b", "b + a")
      wc:propset("color", "red", "src")

      assert.is_true(revert.files { "src" })

      assert.are.same({}, wc:status())
    end)

    it("restores a deleted directory", function()
      wc:delete("src")
      assert.is_false(wc:exists("src/main.c"))

      assert.is_true(revert.files { "src" })

      assert.is_true(wc:exists("src/main.c"))
      assert.is_true(wc:exists("src/sub/util.c"))
      assert.are.same({}, wc:status())
    end)

    it("takes reverted files out of the staging changelist", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGED, "a.txt", "b.txt")
      wc:changelist("other", "src/main.c")

      assert.is_true(revert.files { "a.txt", "src/main.c" })

      assert.are.same({ "b.txt" }, wc:members(STAGED))
      -- Other changelists are the user's business
      assert.are.same({ "src/main.c" }, wc:members("other"))
    end)

    it("reverts a staged new directory without complaining", function()
      wc:write("newdir/x.txt", "x\n")
      changelist.stage { "newdir" }

      local notifications = util.capture_notifications(function()
        assert.is_true(revert.files { "newdir" })
      end)

      assert.are.same({}, notifications)
      assert.are.same({ "?       newdir" }, wc:status())
      assert.are.same("x\n", wc:read("newdir/x.txt"))
    end)

    it("drops a conflict", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:update()

      assert.is_true(revert.files { "a.txt" })

      assert.are.same({}, wc:status())
      assert.is_truthy(wc:read("a.txt"):find("line 5 from the other working copy", 1, true))
    end)

    it("accepts absolute paths and odd file names", function()
      wc:write("icon@2x.txt", "x\n")
      wc:write("with space.txt", "x\n")
      wc:add("icon@2x.txt", "with space.txt")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      assert.is_true(revert.files { "icon@2x.txt", "with space.txt", wc:abs("a.txt") })

      assert.are.same({ "?       icon@2x.txt", "?       with space.txt" }, wc:status())
    end)
  end)

  describe("#hunk", function()
    local original

    before_each(function()
      original = wc:read("a.txt")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\nan added line\n")
    end)

    it("reverts a single hunk and leaves the others alone", function()
      local item = find(wc:refresh(), "a.txt")
      assert.are.same(2, #item.diff.hunks)

      local ok, err = revert.hunk(item, item.diff.hunks[2])

      assert.is_nil(err)
      assert.is_true(ok)

      local content = wc:read("a.txt")
      assert.is_truthy(content:find("line 2 changed\n", 1, true))
      assert.is_truthy(content:find("line 18\n", 1, true))
      assert.is_falsy(content:find("line 18 changed", 1, true))
      assert.is_falsy(content:find("an added line", 1, true))

      -- Only the first hunk is left
      local diffs = require("sven.lib.svn.diff").working({ "a.txt" }).diffs
      assert.are.same(1, #diffs[1].hunks)
      assert.are.same("@@ -1,5 +1,5 @@", diffs[1].hunks[1].line)
    end)

    it("reverts the first hunk, which shifts nothing below it", function()
      local item = find(wc:refresh(), "a.txt")

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))

      local content = wc:read("a.txt")
      assert.is_truthy(content:find("line 2\n", 1, true))
      assert.is_truthy(content:find("line 18 changed\nan added line\n", 1, true))
    end)

    it("reverts all hunks one by one back to the pristine file", function()
      local item = find(wc:refresh(), "a.txt")

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))
      assert.is_true(revert.hunk(item, item.diff.hunks[2]))

      assert.are.same(original, wc:read("a.txt"))
      assert.are.same({}, wc:status())
    end)

    it("reverts some lines of a hunk", function()
      local item = find(wc:refresh(), "a.txt")
      local hunk = item.diff.hunks[2]

      -- " line 15", " line 16", " line 17", "-line 18", "+line 18 changed", "+an added line", ...
      assert.are.same("+an added line", hunk.lines[6])

      assert.is_true(revert.hunk(item, hunk, { from = 6, to = 6 }))

      local content = wc:read("a.txt")
      assert.is_truthy(content:find("line 18 changed\nline 19\n", 1, true))
      assert.is_falsy(content:find("an added line", 1, true))
    end)

    it("leaves the file in the staging changelist", function()
      wc:changelist(STAGED, "a.txt")
      local item = find(wc:refresh(), "a.txt")

      assert.is_true(revert.hunk(item, item.diff.hunks[2]))

      assert.are.same({ "a.txt" }, wc:members(STAGED))
    end)

    it("fails without touching the file when the hunk is stale", function()
      local item = find(wc:refresh(), "a.txt")
      local hunk = item.diff.hunks[2]

      -- The file changes behind the back of the diff
      wc:replace("a.txt", "line 18 changed\nan added line\n", "something else entirely\n")
      local content = wc:read("a.txt")

      local ok, err
      local notifications = util.capture_notifications(function()
        ok, err = revert.hunk(item, hunk)
      end)

      assert.is_false(ok)
      assert.is_string(err)
      assert.are.same(1, #notifications)
      assert.are.same(content, wc:read("a.txt"))
      -- No reject file is left behind
      assert.are.same({ "M       a.txt" }, wc:status())
    end)

    it("refuses files that are not modified", function()
      wc:write("added.txt", "added\n")
      wc:add("added.txt")
      local item = find(wc:refresh(), "added.txt")

      local ok, err
      util.capture_notifications(function()
        ok, err = revert.hunk(item, item.diff.hunks[1])
      end)

      assert.is_false(ok)
      assert.is_truthy(err:match("added"))
      assert.are.same("A", wc:status_of("added.txt"))
    end)
  end)

  describe("#hunk with special content", function()
    it("keeps the line endings of a CRLF file", function()
      wc:write("crlf.txt", "one\r\ntwo\r\nthree\r\nfour\r\n")
      wc:add("crlf.txt")
      wc:commit("Add a CRLF file")

      wc:write("crlf.txt", "one\r\nTWO\r\nthree\r\nfour\r\n")
      local item = find(wc:refresh(), "crlf.txt")
      assert.are.same("+TWO", item.diff.hunks[1].lines[3])

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))

      assert.are.same("one\r\ntwo\r\nthree\r\nfour\r\n", wc:read("crlf.txt"))
      assert.are.same({}, wc:status())
    end)

    it("restores a missing newline at the end of the file", function()
      wc:write("noeol.txt", "changed, and now with a newline\n")
      local item = find(wc:refresh(), "noeol.txt")

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))

      assert.are.same("no newline at the end", wc:read("noeol.txt"))
      assert.are.same({}, wc:status())
    end)

    it("works for paths with spaces and an @", function()
      wc:write("a dir/icon@2x.txt", "one\ntwo\nthree\n")
      wc:add("a dir")
      wc:commit("Add an oddly named file")

      wc:write("a dir/icon@2x.txt", "one\nTWO\nthree\n")
      local item = find(wc:refresh(), "a dir/icon@2x.txt")

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))

      assert.are.same("one\ntwo\nthree\n", wc:read("a dir/icon@2x.txt"))
    end)

    it("empties a file whose pristine copy is empty, without deleting it", function()
      wc:write("empty.txt", "")
      wc:add("empty.txt")
      wc:commit("Add an empty file")

      wc:write("empty.txt", "content\n")
      local item = find(wc:refresh(), "empty.txt")
      assert.are.same("modified", item.status)

      assert.is_true(revert.hunk(item, item.diff.hunks[1]))

      assert.are.same("", wc:read("empty.txt"))
      assert.are.same({}, wc:status())
    end)
  end)

  describe("#unversioned", function()
    it("deletes unversioned files and directories", function()
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")

      local ok, failed = revert.unversioned { "new.txt", "newdir" }

      assert.is_true(ok)
      assert.are.same({}, failed)
      assert.is_false(wc:exists("new.txt"))
      assert.is_false(wc:exists("newdir"))
      assert.are.same({}, wc:status())
    end)

    it("refuses to delete anything svn tracks", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("added.txt", "added\n")
      wc:add("added.txt")
      wc:write("new.txt", "new\n")

      local ok, failed
      local notifications = util.capture_notifications(function()
        ok, failed = revert.unversioned { "a.txt", "added.txt", "b.txt", "src", "new.txt", "." }
      end)

      assert.is_false(ok)
      assert.are.same({ "a.txt", "added.txt", "b.txt", "src", "." }, failed)
      assert.are.same(1, #notifications)

      assert.is_true(wc:exists("a.txt"))
      assert.is_true(wc:exists("added.txt"))
      assert.is_true(wc:exists("b.txt"))
      assert.is_true(wc:exists("src/main.c"))
      assert.is_false(wc:exists("new.txt"))
    end)

    it("accepts absolute paths", function()
      wc:write("new.txt", "new\n")

      assert.is_true(revert.unversioned { wc:abs("new.txt") })
      assert.is_false(wc:exists("new.txt"))
    end)
  end)
end)
