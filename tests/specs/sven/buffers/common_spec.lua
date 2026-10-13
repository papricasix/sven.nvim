local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

---@return string[] The lines of the current buffer, without trailing whitespace
local function buffer_lines()
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
end

---The components shared by the views, fed with what the svn backend produces
describe("buffers.common", function()
  local common, Buffer, svn, wc
  local buffer

  ---Renders components into a scratch buffer
  ---@param components table[]
  local function render(components)
    buffer = Buffer.create {
      name = "SvenSpec",
      filetype = "SvenSpec",
      kind = "split",
      render = function()
        return components
      end,
    }
  end

  ---@param name string
  ---@return SvenStatusItem
  local function item(name)
    return assert(svn.status.find(name), "No item named " .. name)
  end

  before_each(function()
    wc = harness.create()
    common = require("sven.buffers.common")
    Buffer = require("sven.lib.buffer")
    svn = require("sven.lib.svn")
  end)

  after_each(function()
    if buffer then
      buffer:close()
      buffer = nil
    end

    util.reset_editor()
    harness.cleanup()
  end)

  describe("Diff", function()
    it("renders the diff of a modified file", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      wc:refresh()

      render { common.Diff(item("a.txt").diff) }

      assert.are.same({
        "modified a.txt",
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
      }, buffer_lines())
    end)

    it("makes the hunks foldable and findable", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18 changed\n")
      wc:refresh()

      local diff = item("a.txt").diff
      render { common.Diff(diff) }

      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      local found = buffer.ui:get_hunk_or_filename_under_cursor()
      assert.are.equal(diff.hunks[1], found.hunk)

      vim.api.nvim_win_set_cursor(0, { 13, 0 })
      found = buffer.ui:get_hunk_or_filename_under_cursor()
      assert.are.equal(diff.hunks[2], found.hunk)

      -- Fold the second hunk: from its header to its last line
      vim.cmd("normal! zc")
      assert.are.same(9, vim.fn.foldclosed(13))
      assert.are.same(16, vim.fn.foldclosedend(13))
    end)

    it("highlights added and removed lines", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:refresh()

      render { common.Diff(item("a.txt").diff) }

      assert.are.same("SvenDiffHeader", buffer.ui:get_line_highlight(1))
      assert.are.same("SvenHunkHeader", buffer.ui:get_line_highlight(2))
      assert.are.same("SvenDiffContext", buffer.ui:get_line_highlight(3))
      assert.are.same("SvenDiffDelete", buffer.ui:get_line_highlight(4))
      assert.are.same("SvenDiffAdd", buffer.ui:get_line_highlight(5))
    end)

    it("renders added, deleted and unversioned files", function()
      wc:write("added.txt", "added\n")
      wc:add("added.txt")
      wc:delete("b.txt")
      wc:write("new.txt", "new\n")
      wc:refresh()

      render {
        common.Diff(item("added.txt").diff),
        common.Diff(item("b.txt").diff),
        common.Diff(item("new.txt").diff),
      }

      assert.are.same({
        "added added.txt",
        "@@ -0,0 +1 @@",
        "+added",
        "deleted b.txt",
        "@@ -1 +0,0 @@",
        "-hello",
        "unversioned new.txt",
        "@@ -0,0 +1 @@",
        "+new",
      }, buffer_lines())
    end)

    it("renders property changes and binary files as information lines", function()
      wc:propset("svn:eol-style", "native", "src/sub/util.c")
      wc:write("blob.bin", "a\0b\0c")
      wc:add("blob.bin")
      wc:refresh()

      render {
        common.Diff(item("src/sub/util.c").diff),
        common.Diff(item("blob.bin").diff),
      }

      assert.are.same({
        "modified src/sub/util.c",
        "Added: svn:eol-style",
        "## -0,0 +1 ##",
        "+native",
        "\\ No newline at end of property",
        "added blob.bin",
        "Cannot display: file marked as a binary type.",
        "svn:mime-type = application/octet-stream",
        "Added: svn:mime-type",
        "## -0,0 +1 ##",
        "+application/octet-stream",
        "\\ No newline at end of property",
      }, buffer_lines())
    end)

    it("renders the diffs of a revision", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:add("new.txt")
      local revision = wc:commit("Change and add")

      local result = svn.diff.revision(revision)
      render(vim.tbl_map(common.Diff, result.diffs))

      local lines = buffer_lines()
      assert.are.same("modified a.txt", lines[1])
      assert.is_true(vim.tbl_contains(lines, "added new.txt"))
      assert.is_true(vim.tbl_contains(lines, "+new"))
    end)
  end)

  describe("CommitEntry", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:commit("Change line 2\n\nBecause it had to be done.")
    end)

    it("renders log entries as rows", function()
      local entries = svn.log.list { limit = 2 }

      render(vim.tbl_map(function(entry)
        return common.CommitEntry(entry, {}, {})
      end, entries))

      assert.are.same({ "r3  Change line 2", "r2  Add the initial files" }, buffer_lines())
      assert.are.same("3", buffer.ui:get_commit_under_cursor())

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.are.same("2", buffer.ui:get_commit_under_cursor())
      assert.is_not_nil(buffer.ui:find_component_by_oid("3"))
    end)

    it("renders the details of an entry", function()
      local entry = svn.log.list({ limit = 1 })[1]

      render { common.CommitEntry(entry, {}, { details = true }) }
      vim.cmd("normal! zR")

      local lines = buffer_lines()
      assert.are.same("r3  Change line 2", lines[1])
      assert.is_true(vim.tbl_contains(lines, ("    Author:     %s <>"):format(vim.env.USER)))
      assert.is_true(vim.tbl_contains(lines, "    Change line 2"))
      assert.is_true(vim.tbl_contains(lines, "    Because it had to be done."))
    end)
  end)
end)
