local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@param buf integer|nil
---@return string[] The lines of a buffer, without trailing whitespace
local function lines(buf)
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false))
end

---Puts the cursor on the first line with this text
---@param text string
local function goto_line(text)
  for index, line in ipairs(lines()) do
    if line == text then
      vim.api.nvim_win_set_cursor(0, { index, 0 })
      return
    end
  end

  error(("No line %q in the buffer"):format(text))
end

describe("buffers.diff", function()
  local wc
  local svn
  local DiffBuffer

  ---Opens the diff buffer with the local changes of the working copy
  ---@param kind string|nil
  ---@return SvenDiffBuffer
  local function open(kind)
    local result = svn.diff.working()
    return DiffBuffer.new({
      header = "Changes in the working copy",
      diffs = result.diffs,
      stats = result.stats,
    }):open(kind)
  end

  before_each(function()
    wc = harness.create()
    svn = require("sven.lib.svn")
    DiffBuffer = require("sven.buffers.diff")
  end)

  after_each(function()
    util.reset_editor()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.startswith(vim.api.nvim_buf_get_name(buf), wc.path) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    harness.cleanup()
  end)

  it("renders a header, an overview and the diffs", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("a.txt", "line 18\n", "line 18 changed\nline 18b\n")
    wc:write("new.txt", "brand new\n")
    wc:add("new.txt")
    wc:delete("b.txt")

    local view = open()

    assert.are.same("SvenDiffView", vim.bo.filetype)
    assert.is_true(view:is_open())
    assert.is_false(vim.bo.modifiable)
    assert.are.same("nofile", vim.bo.buftype)

    assert.are.same({
      "Changes in the working copy",
      "3 files changed, 4 insertions(+), 3 deletions(-)",
      "a.txt    |     5  +++--",
      "b.txt    |     1  -",
      "new.txt  |     1  +",
      "",
      "modified a.txt",
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
      "+line 18b",
      " line 19",
      " line 20",
      "deleted b.txt",
      "@@ -1 +0,0 @@",
      "-hello",
      "added new.txt",
      "@@ -0,0 +1 @@",
      "+brand new",
    }, lines())
  end)

  it("opens in a split below by default, and in the kind it is told", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    local window = vim.api.nvim_get_current_win()

    local view = open()

    assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are_not.same(window, vim.api.nvim_get_current_win())
    assert.are.same(1, #vim.api.nvim_list_tabpages())

    view:close()
    assert.is_true(util.wait_for(function()
      return #vim.api.nvim_tabpage_list_wins(0) == 1
    end))

    open("tab")
    assert.are.same(2, #vim.api.nvim_list_tabpages())
    assert.are.same("SvenDiffView", vim.bo.filetype)
  end)

  it("does not open without diffs", function()
    local view = open()

    assert.is_false(view:is_open())
    assert.is_nil(view.buffer)
    assert.are_not.same("SvenDiffView", vim.bo.filetype)
    assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("shows what svn says about binary files and property changes", function()
    wc:write("image.bin", "a\0b\0c")
    wc:add("image.bin")
    wc:propset("svn:eol-style", "native", "b.txt")

    open()

    assert.are.same({
      "Changes in the working copy",
      "2 files changed",
      "b.txt      | props",
      "image.bin  |   Bin",
      "",
      "modified b.txt",
      "Added: svn:eol-style",
      "## -0,0 +1 ##",
      "+native",
      "\\ No newline at end of property",
      -- svn prints nothing that tells a binary file is new: the diff parser calls it modified
      "modified image.bin",
      "Cannot display: file marked as a binary type.",
      "svn:mime-type = application/octet-stream",
      "Added: svn:mime-type",
      "## -0,0 +1 ##",
      "+application/octet-stream",
      "\\ No newline at end of property",
    }, lines())
  end)

  it("folds files and hunks, all open at first", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("b.txt", "hello", "bye")

    open()

    for line = 1, vim.fn.line("$") do
      assert.are.same(-1, vim.fn.foldclosed(line))
    end

    goto_line("modified a.txt")
    feed("<tab>")

    local first = vim.fn.line(".")
    assert.are.same(first, vim.fn.foldclosed(first))
    assert.are.same(first + 7, vim.fn.foldclosedend(first))

    feed("<tab>")
    assert.are.same(-1, vim.fn.foldclosed(first))

    goto_line("@@ -1 +1 @@")
    feed("<tab>")
    assert.are.same(vim.fn.line("."), vim.fn.foldclosed("."))
    assert.are.same(vim.fn.line(".") + 2, vim.fn.foldclosedend("."))
  end)

  it("moves between the headers of files and hunks", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("a.txt", "line 18\n", "line 18 changed\n")
    wc:replace("b.txt", "hello", "bye")

    open()
    goto_line("modified a.txt")

    feed("}")
    assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())
    feed("}")
    assert.are.same("@@ -15,6 +15,6 @@", vim.api.nvim_get_current_line())
    feed("}")
    assert.are.same("modified b.txt", vim.api.nvim_get_current_line())

    feed("{")
    assert.are.same("@@ -15,6 +15,6 @@", vim.api.nvim_get_current_line())
    feed("{")
    assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())
  end)

  it("goes to the line of the working file with <cr>", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("a.txt", "line 18\n", "line 18 changed\nline 18b\n")

    open()
    goto_line(" line 19")
    feed("<cr>")

    assert.is_true(util.wait_for(function()
      return vim.api.nvim_buf_get_name(0) == wc:abs("a.txt")
    end))
    -- One line was added above it
    assert.are.same(20, vim.fn.line("."))
    assert.are.same("line 19", vim.api.nvim_get_current_line())
  end)

  it("goes from a row of the overview to the diff of that file, or to the file", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("b.txt", "hello", "bye")

    open()
    goto_line("b.txt  |     2  +-")
    feed("<cr>")

    assert.are.same("SvenDiffView", vim.bo.filetype)
    assert.are.same("modified b.txt", vim.api.nvim_get_current_line())

    goto_line("b.txt  |     2  +-")
    feed("a")

    assert.is_true(util.wait_for(function()
      return vim.api.nvim_buf_get_name(0) == wc:abs("b.txt")
    end))
  end)

  it("closes with q", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")

    local view = open()
    feed("q")

    assert.is_true(util.wait_for(function()
      return vim.bo.filetype ~= "SvenDiffView"
    end))
    assert.is_false(view:is_open())
  end)

  describe("ui", function()
    local ui

    before_each(function()
      ui = require("sven.buffers.diff.ui")
    end)

    ---@param additions number
    ---@param deletions number
    ---@return Diff
    local function diff(additions, deletions)
      return { file = "f", stats = { additions = additions, deletions = deletions }, props = {}, hunks = {} }
    end

    it("sums up what changed", function()
      assert.are.same("1 file changed", ui.summary { diff(0, 0) })
      assert.are.same("1 file changed, 1 insertion(+)", ui.summary { diff(1, 0) })
      assert.are.same("1 file changed, 1 deletion(-)", ui.summary { diff(0, 1) })
      assert.are.same(
        "2 files changed, 5 insertions(+), 3 deletions(-)",
        ui.summary { diff(2, 3), diff(3, 0) }
      )
      assert.are.same(
        "2 files changed, 7 insertions(+)",
        ui.summary({ diff(2, 3), diff(3, 0) }, { additions = 7, deletions = 0 })
      )
    end)

    it("scales the bars of large changes down", function()
      ---@param additions number
      ---@param deletions number
      ---@return string
      local function row(additions, deletions)
        local component = ui.OverviewFile(1)(diff(additions, deletions))
        return table.concat(vim.tbl_map(function(child)
          return child.value
        end, component.children))
      end

      assert.are.same("f  |     5  +++--", row(3, 2))
      assert.are.same("f  |   400  " .. ("+"):rep(30) .. ("-"):rep(10), row(300, 100))
      -- A side with changes keeps at least one character
      assert.are.same("f  |  1001  " .. ("+"):rep(39) .. "-", row(1000, 1))
      assert.are.same("f  |   500  " .. ("-"):rep(40), row(0, 500))
    end)
  end)
end)
