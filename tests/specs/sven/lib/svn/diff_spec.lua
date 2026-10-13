local harness = require("tests.util.svn_harness")
local diff = require("sven.lib.svn.diff")

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

local SEPARATOR = string.rep("=", 67)

describe("lib.svn.diff", function()
  describe("#parse", function()
    it("parses a modified file with two hunks", function()
      local diffs = diff.parse {
        "Index: a.txt",
        SEPARATOR,
        "--- a.txt\t(revision 2)",
        "+++ a.txt\t(working copy)",
        "@@ -1,5 +1,5 @@",
        " line 1",
        "-line 2",
        "+line 2 changed",
        " line 3",
        " line 4",
        " line 5",
        "@@ -15,6 +15,7 @@",
        " line 15",
        " line 16",
        " line 17",
        "-line 18",
        "+line 18 changed",
        "+another line",
        " line 19",
        " line 20",
        "",
      }

      assert.are.same(1, #diffs)

      local d = diffs[1]
      assert.are.same("modified", d.kind)
      assert.are.same("a.txt", d.file)
      assert.are.same("revision 2", d.old_label)
      assert.are.same("working copy", d.new_label)
      assert.are.same({ additions = 3, deletions = 2 }, d.stats)
      assert.are.same({}, d.info)
      assert.is_false(d.binary)
      assert.is_false(d.props_only)
      assert.are.same(
        { "Index: a.txt", SEPARATOR, "--- a.txt\t(revision 2)", "+++ a.txt\t(working copy)" },
        d.header
      )
      assert.are.same("@@ -1,5 +1,5 @@", d.lines[1])
      assert.are.same(16, #d.lines)

      assert.are.same(2, #d.hunks)

      local first, second = d.hunks[1], d.hunks[2]
      assert.are.same("@@ -1,5 +1,5 @@", first.line)
      assert.are.same(1, first.index_from)
      assert.are.same(5, first.index_len)
      assert.are.same(1, first.disk_from)
      assert.are.same(5, first.disk_len)
      assert.are.same(1, first.diff_from)
      assert.are.same(7, first.diff_to)
      assert.are.same(6, first.length)
      assert.are.same("a.txt", first.file)
      assert.are.same(
        { " line 1", "-line 2", "+line 2 changed", " line 3", " line 4", " line 5" },
        first.lines
      )

      assert.are.same("@@ -15,6 +15,7 @@", second.line)
      assert.are.same(15, second.index_from)
      assert.are.same(6, second.index_len)
      assert.are.same(15, second.disk_from)
      assert.are.same(7, second.disk_len)
      assert.are.same(8, second.diff_from)
      assert.are.same(16, second.diff_to)
      assert.are.same(8, second.length)
      assert.are.same(" line 20", second.lines[#second.lines])

      assert.are.same(64, #first.hash)
      assert.are_not.same(first.hash, second.hash)

      -- What the vendored Diff/Hunk components read
      assert.are.same(first.line, d.lines[first.diff_from])
      assert.are.same(second.line, d.lines[second.diff_from])
      assert.are.same(first.lines, d.pager_contents[1])
      assert.are.same(second.lines, d.pager_contents[2])
    end)

    it("parses an added file", function()
      local d = diff.parse({
        "Index: added.txt",
        SEPARATOR,
        "--- added.txt\t(nonexistent)",
        "+++ added.txt\t(working copy)",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second",
      })[1]

      assert.are.same("added", d.kind)
      assert.are.same("added.txt", d.file)
      assert.are.same({ additions = 2, deletions = 0 }, d.stats)
      assert.are.same(0, d.hunks[1].index_from)
      assert.are.same(0, d.hunks[1].index_len)
      assert.are.same(1, d.hunks[1].disk_from)
      assert.are.same(2, d.hunks[1].disk_len)
    end)

    it("parses a deleted file", function()
      local d = diff.parse({
        "Index: b.txt",
        SEPARATOR,
        "--- b.txt\t(revision 2)",
        "+++ b.txt\t(nonexistent)",
        "@@ -1 +0,0 @@",
        "-hello",
      })[1]

      assert.are.same("deleted", d.kind)
      assert.are.same({ additions = 0, deletions = 1 }, d.stats)
      assert.are.same(1, d.hunks[1].index_from)
      assert.are.same(1, d.hunks[1].index_len)
      assert.are.same(0, d.hunks[1].disk_from)
      assert.are.same(0, d.hunks[1].disk_len)
    end)

    it("parses a property-only change", function()
      local d = diff.parse({
        "Index: src/sub/util.c",
        SEPARATOR,
        "--- src/sub/util.c\t(revision 2)",
        "+++ src/sub/util.c\t(working copy)",
        "",
        "Property changes on: src/sub/util.c",
        "___________________________________________________________________",
        "Added: svn:eol-style",
        "## -0,0 +1 ##",
        "+native",
        "\\ No newline at end of property",
        "Modified: color",
        "## -1 +1 ##",
        "-blue",
        "+red",
        "\\ No newline at end of property",
      })[1]

      assert.are.same("modified", d.kind)
      assert.are.same("src/sub/util.c", d.file)
      assert.is_true(d.props_only)
      assert.are.same({}, d.hunks)
      assert.are.same({}, d.lines)
      assert.are.same({ additions = 0, deletions = 0 }, d.stats)

      assert.are.same(2, #d.props)
      assert.are.same("svn:eol-style", d.props[1].name)
      assert.are.same("Added", d.props[1].action)
      assert.are.same({ "## -0,0 +1 ##", "+native", "\\ No newline at end of property" }, d.props[1].lines)
      assert.are.same("color", d.props[2].name)
      assert.are.same("Modified", d.props[2].action)

      assert.are.same("Added: svn:eol-style", d.info[1])
      assert.are.same("+native", d.info[3])
      assert.are.same("Modified: color", d.info[5])
    end)

    it("parses text changes followed by property changes", function()
      local d = diff.parse({
        "Index: a.txt",
        SEPARATOR,
        "--- a.txt\t(revision 2)",
        "+++ a.txt\t(working copy)",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "",
        "Property changes on: a.txt",
        "___________________________________________________________________",
        "Deleted: color",
        "## -1 +0,0 ##",
        "-blue",
      })[1]

      assert.is_false(d.props_only)
      assert.are.same(1, #d.hunks)
      assert.are.same({ "-old", "+new" }, d.hunks[1].lines)
      assert.are.same("Deleted", d.props[1].action)
      assert.are.same({ additions = 1, deletions = 1 }, d.stats)
    end)

    it("parses a binary file", function()
      local d = diff.parse({
        "Index: bin.dat",
        SEPARATOR,
        "Cannot display: file marked as a binary type.",
        "svn:mime-type = application/octet-stream",
        "",
        "Property changes on: bin.dat",
        "___________________________________________________________________",
        "Added: svn:mime-type",
        "## -0,0 +1 ##",
        "+application/octet-stream",
        "\\ No newline at end of property",
      })[1]

      assert.are.same("bin.dat", d.file)
      assert.is_true(d.binary)
      assert.is_false(d.props_only)
      assert.are.same({}, d.hunks)
      assert.are.same("Cannot display: file marked as a binary type.", d.info[1])
      assert.are.same("svn:mime-type = application/octet-stream", d.info[2])
      assert.are.same("svn:mime-type", d.props[1].name)
    end)

    it("parses several files in one output", function()
      local diffs = diff.parse {
        "Index: a.txt",
        SEPARATOR,
        "--- a.txt\t(revision 2)",
        "+++ a.txt\t(working copy)",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "Index: dir with space/b c.txt",
        SEPARATOR,
        "--- dir with space/b c.txt\t(nonexistent)",
        "+++ dir with space/b c.txt\t(working copy)",
        "@@ -0,0 +1 @@",
        "+content",
        "Index: .",
        SEPARATOR,
        "--- .\t(revision 2)",
        "+++ .\t(working copy)",
        "",
        "Property changes on: .",
        "___________________________________________________________________",
        "Added: foo",
        "## -0,0 +1 ##",
        "+bar",
      }

      assert.are.same(
        { "a.txt", "dir with space/b c.txt", "." },
        vim.tbl_map(function(d)
          return d.file
        end, diffs)
      )
      assert.are.same(
        { "modified", "added", "modified" },
        vim.tbl_map(function(d)
          return d.kind
        end, diffs)
      )
      assert.are.same({ "-old", "+new" }, diffs[1].hunks[1].lines)
      assert.are.same("dir with space/b c.txt", diffs[2].hunks[1].file)
      assert.is_true(diffs[3].props_only)
    end)

    it("keeps the missing newline marker inside the hunk", function()
      local d = diff.parse({
        "Index: noeol.txt",
        SEPARATOR,
        "--- noeol.txt\t(revision 2)",
        "+++ noeol.txt\t(working copy)",
        "@@ -1 +1 @@",
        "-no newline at the end",
        "\\ No newline at end of file",
        "+changed",
        "\\ No newline at end of file",
      })[1]

      assert.are.same({
        "-no newline at the end",
        "\\ No newline at end of file",
        "+changed",
        "\\ No newline at end of file",
      }, d.hunks[1].lines)
      assert.are.same({ additions = 1, deletions = 1 }, d.stats)
    end)

    it("strips carriage returns for display and keeps the raw lines", function()
      local d = diff.parse({
        "Index: crlf.txt",
        SEPARATOR,
        "--- crlf.txt\t(revision 2)",
        "+++ crlf.txt\t(working copy)",
        "@@ -1,2 +1,2 @@",
        " one\r",
        "-two\r",
        "+TWO\r",
      })[1]

      assert.are.same({ " one", "-two", "+TWO" }, d.hunks[1].lines)
      assert.are.same({ " one\r", "-two\r", "+TWO\r" }, d.hunks[1].raw)
    end)

    it("accepts the output as one string", function()
      local diffs = diff.parse(table.concat({
        "Index: a.txt",
        SEPARATOR,
        "--- a.txt\t(revision 2)",
        "+++ a.txt\t(working copy)",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "",
      }, "\n"))

      assert.are.same(1, #diffs)
      assert.are.same({ "-old", "+new" }, diffs[1].hunks[1].lines)
    end)

    it("returns nothing for empty output", function()
      assert.are.same({}, diff.parse {})
      assert.are.same({}, diff.parse { "" })
    end)
  end)

  describe("#generate_patch", function()
    local hunk

    before_each(function()
      hunk = diff.parse({
        "Index: a.txt",
        SEPARATOR,
        "--- a.txt\t(revision 2)",
        "+++ a.txt\t(working copy)",
        "@@ -1,4 +1,5 @@",
        " one",
        "-two",
        "+TWO",
        "+two and a half",
        " three",
        " four",
      })[1].hunks[1]
    end)

    it("builds a patch for the whole hunk", function()
      assert.are.same(
        table.concat({
          "Index: a.txt",
          SEPARATOR,
          "--- a.txt\t(revision BASE)",
          "+++ a.txt\t(working copy)",
          "@@ -1,4 +1,5 @@",
          " one",
          "-two",
          "+TWO",
          "+two and a half",
          " three",
          " four",
          "",
        }, "\n"),
        diff.generate_patch(hunk, { reverse = true })
      )
    end)

    it("builds a patch for some lines, to be applied in reverse", function()
      -- Only "+two and a half" is selected: the other changes become context
      local patch = diff.generate_patch(hunk, { from = 4, to = 4, reverse = true })

      assert.are.same({
        "@@ -1,4 +1,5 @@",
        " one",
        " TWO",
        "+two and a half",
        " three",
        " four",
      }, vim.list_slice(vim.split(patch, "\n"), 5, 10))
    end)

    it("builds a patch for some lines, to be applied forwards", function()
      local patch = diff.generate_patch(hunk, { from = 2, to = 3 })

      assert.are.same({
        "@@ -1,4 +1,4 @@",
        " one",
        "-two",
        "+TWO",
        " three",
        " four",
      }, vim.list_slice(vim.split(patch, "\n"), 5, 10))
    end)

    it("uses the raw lines of CRLF files", function()
      local crlf = diff.parse({
        "Index: crlf.txt",
        SEPARATOR,
        "--- crlf.txt\t(revision 2)",
        "+++ crlf.txt\t(working copy)",
        "@@ -1,2 +1,2 @@",
        " one\r",
        "-two\r",
        "+TWO\r",
      })[1].hunks[1]

      local patch = diff.generate_patch(crlf, { reverse = true })

      assert.is_truthy(patch:find("\n one\r\n-two\r\n+TWO\r\n", 1, true))
      assert.is_truthy(patch:find("Index: crlf.txt\n", 1, true))
    end)
  end)

  describe("in a working copy", function()
    local wc

    before_each(function()
      wc = harness.create()
    end)

    after_each(function()
      harness.cleanup()
    end)

    it("diffs the working copy", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")

      local result = diff.working()

      assert.are.same(
        { "a.txt", "src/main.c" },
        vim.tbl_map(function(d)
          return d.file
        end, result.diffs)
      )
      assert.are.same({ additions = 2, deletions = 2 }, result.stats)
      assert.are.same(wc:svn("diff"), result.raw)
      assert.are.same("Index: a.txt", result.lines[1])
    end)

    it("diffs some paths only", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")

      local result = diff.working { "src" }

      assert.are.same(1, #result.diffs)
      assert.are.same("src/main.c", result.diffs[1].file)
      assert.are.same({ "-  return 0;", "+  return 1;" }, {
        result.diffs[1].hunks[1].lines[4],
        result.diffs[1].hunks[1].lines[5],
      })
    end)

    it("diffs the staged files", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("sven-staged", "src/main.c")

      local result = diff.staged()

      assert.are.same(1, #result.diffs)
      assert.are.same("src/main.c", result.diffs[1].file)
    end)

    it("diffs a revision", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:add("new.txt")
      wc:delete("b.txt")
      local revision = wc:commit("Change, add and delete")

      local result = diff.revision(revision)

      local by_file = {}
      for _, d in ipairs(result.diffs) do
        by_file[d.file] = d
      end

      assert.are.same("modified", by_file["a.txt"].kind)
      assert.are.same("added", by_file["new.txt"].kind)
      assert.are.same("deleted", by_file["b.txt"].kind)
      assert.are.same({ "+new" }, by_file["new.txt"].hunks[1].lines)
      assert.are.same({ "-hello" }, by_file["b.txt"].hunks[1].lines)
      assert.are.same("revision " .. revision, by_file["a.txt"].new_label)
    end)

    it("diffs a revision of the whole repository", function()
      local revision = wc:head()

      local result = diff.revision(revision, { "^/" })

      assert.is_truthy(vim.tbl_contains(
        vim.tbl_map(function(d)
          return d.file
        end, result.diffs),
        "trunk/src/main.c"
      ))
    end)

    it("handles an @ in a file name in every mode", function()
      -- svn takes the paths of a working copy diff literally, and parses a peg revision off
      -- them in all other modes
      wc:write("a dir/icon@2x.txt", "one\ntwo\nthree\n")
      wc:add("a dir")
      local revision = wc:commit("Add an oddly named file")
      wc:write("a dir/icon@2x.txt", "one\nTWO\nthree\n")

      local working = diff.working { "a dir/icon@2x.txt" }
      assert.are.same("a dir/icon@2x.txt", working.diffs[1].file)
      assert.are.same("modified", working.diffs[1].kind)

      local base = diff.run { revision = "BASE", paths = { "a dir/icon@2x.txt" } }
      assert.are.same("modified", base.diffs[1].kind)

      local committed = diff.revision(revision, { "a dir/icon@2x.txt" })
      assert.are.same("a dir/icon@2x.txt", committed.diffs[1].file)
      assert.are.same("added", committed.diffs[1].kind)

      local range = diff.range(revision - 1, revision, { "a dir" })
      assert.are.same("added", range.diffs[1].kind)
    end)

    it("diffs a range of revisions for a path", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      local first = wc:commit("Change line 2")
      wc:replace("a.txt", "line 19\n", "line 19 changed\n")
      wc:replace("b.txt", "hello", "bye")
      local second = wc:commit("Change line 19 and b.txt")

      local result = diff.range(first - 1, second, { "a.txt" })

      assert.are.same(1, #result.diffs)
      assert.are.same("a.txt", result.diffs[1].file)
      assert.are.same(2, #result.diffs[1].hunks)
      assert.are.same({ additions = 2, deletions = 2 }, result.stats)
    end)

    describe("of status items", function()
      it("loads the diff of a modified file lazily and caches it", function()
        wc:replace("a.txt", "line 2\n", "line 2 changed\n")
        local item = find(wc:refresh(), "a.txt")

        assert.is_nil(rawget(item, "diff"))

        local d = item.diff
        assert.are.same("modified", d.kind)
        assert.are.same("a.txt", d.file)
        assert.are.same(1, #d.hunks)
        assert.are.same("-line 2", d.hunks[1].lines[2])
        assert.are.same("+line 2 changed", d.hunks[1].lines[3])

        assert.is_not_nil(rawget(item, "diff"))
        assert.are.equal(d, item.diff)
      end)

      it("builds a diff for an unversioned file", function()
        wc:write("new.txt", "first\nsecond\n")
        local d = find(wc:refresh(), "new.txt").diff

        assert.are.same("unversioned", d.kind)
        assert.are.same("new.txt", d.file)
        assert.are.same("@@ -0,0 +1,2 @@", d.hunks[1].line)
        assert.are.same({ "+first", "+second" }, d.hunks[1].lines)
        assert.are.same({ additions = 2, deletions = 0 }, d.stats)
      end)

      it("marks the missing newline of an unversioned file", function()
        wc:write("new.txt", "only line")
        local d = find(wc:refresh(), "new.txt").diff

        assert.are.same("@@ -0,0 +1 @@", d.hunks[1].line)
        assert.are.same({ "+only line", "\\ No newline at end of file" }, d.hunks[1].lines)
      end)

      it("does not show the content of an unversioned binary", function()
        wc:write("blob.bin", "a\0b\0c")
        local d = find(wc:refresh(), "blob.bin").diff

        assert.is_true(d.binary)
        assert.are.same({}, d.hunks)
        assert.are.same(1, #d.info)
      end)

      it("has an empty diff for an unversioned directory", function()
        wc:write("newdir/x.txt", "x\n")
        local d = find(wc:refresh(), "newdir").diff

        assert.are.same("unversioned", d.kind)
        assert.are.same({}, d.hunks)
      end)

      it("diffs an added file", function()
        wc:write("added.txt", "added\n")
        wc:add("added.txt")
        local d = find(wc:refresh(), "added.txt").diff

        assert.are.same("added", d.kind)
        assert.are.same({ "+added" }, d.hunks[1].lines)
      end)

      it("diffs a deleted file", function()
        wc:delete("b.txt")
        local d = find(wc:refresh(), "b.txt").diff

        assert.are.same("deleted", d.kind)
        assert.are.same({ "-hello" }, d.hunks[1].lines)
      end)

      it("builds a diff for a missing file from its pristine copy", function()
        wc:remove("b.txt")
        local d = find(wc:refresh(), "b.txt").diff

        assert.are.same("missing", d.kind)
        assert.are.same("@@ -1 +0,0 @@", d.hunks[1].line)
        assert.are.same({ "-hello" }, d.hunks[1].lines)
      end)

      it("diffs a property-only change", function()
        wc:propset("svn:eol-style", "native", "src/sub/util.c")
        local d = find(wc:refresh(), "src/sub/util.c").diff

        assert.are.same("modified", d.kind)
        assert.is_true(d.props_only)
        assert.are.same({}, d.hunks)
        assert.are.same("svn:eol-style", d.props[1].name)
        assert.are.same("Added", d.props[1].action)
      end)

      it("only shows the property changes of a directory", function()
        wc:propset("color", "red", "src")
        wc:replace("src/main.c", "return 0", "return 1")
        local d = find(wc:refresh(), "src").diff

        assert.are.same("src", d.file)
        assert.is_true(d.props_only)
        assert.are.same("color", d.props[1].name)
      end)

      it("does not list the content of a deleted directory", function()
        wc:delete("src")
        local d = find(wc:refresh(), "src").diff

        assert.are.same("deleted", d.kind)
        assert.are.same({}, d.hunks)
      end)

      it("diffs an added binary file", function()
        wc:write("blob.bin", "a\0b\0c")
        wc:add("blob.bin")
        local d = find(wc:refresh(), "blob.bin").diff

        assert.are.same("added", d.kind)
        assert.is_true(d.binary)
        assert.are.same({}, d.hunks)
      end)

      it("keeps cached diffs on a partial refresh, except the invalidated ones", function()
        wc:replace("a.txt", "line 2\n", "line 2 changed\n")
        wc:replace("b.txt", "hello", "bye")

        local state = wc:refresh()
        local a_diff = find(state, "a.txt").diff
        local b_diff = find(state, "b.txt").diff

        wc:replace("a.txt", "line 19\n", "line 19 changed\n")
        state = wc:refresh { partial = { update_diffs = { "*:a.txt" } } }

        assert.are.equal(b_diff, rawget(find(state, "b.txt"), "diff"))
        assert.is_nil(rawget(find(state, "a.txt"), "diff"))
        assert.are.same(2, #find(state, "a.txt").diff.hunks)
        assert.are.same(1, #a_diff.hunks)
      end)

      it("drops all cached diffs on a full refresh", function()
        wc:replace("b.txt", "hello", "bye")

        local state = wc:refresh()
        assert.is_not_nil(find(state, "b.txt").diff)

        state = wc:refresh()
        assert.is_nil(rawget(find(state, "b.txt"), "diff"))
      end)
    end)
  end)
end)
