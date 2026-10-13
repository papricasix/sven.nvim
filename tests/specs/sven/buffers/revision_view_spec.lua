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
---@param occurrence integer|nil Which one, when there are several (default 1)
local function goto_line(text, occurrence)
  local seen = 0
  for index, line in ipairs(lines()) do
    if line == text then
      seen = seen + 1
      if seen == (occurrence or 1) then
        vim.api.nvim_win_set_cursor(0, { index, 0 })
        return
      end
    end
  end

  error(("No line %q in the buffer"):format(text))
end

describe("buffers.revision_view", function()
  local wc
  local svn
  local RevisionView

  ---@param revision string|number
  ---@param filter string[]|nil
  ---@param kind string|nil
  ---@return SvenRevisionView
  local function open(revision, filter, kind)
    local view = RevisionView.new(revision, filter):open(kind)
    assert.is_true(view:wait(), "The revision did not load")

    return view
  end

  ---Waits until the current buffer is this file
  ---@param name string Tail of the buffer name
  local function wait_for_buffer(name)
    assert.is_true(
      util.wait_for(function()
        return vim.endswith(vim.api.nvim_buf_get_name(0), name)
      end),
      ("Expected to be in %s, but am in %q"):format(name, vim.api.nvim_buf_get_name(0))
    )
  end

  before_each(function()
    wc = harness.create()
    svn = require("sven.lib.svn")
    RevisionView = require("sven.buffers.revision_view")

    -- r3 changes a file, adds one and deletes one
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("a.txt", "line 18\n", "line 18 changed\n")
    wc:write("new.txt", "brand new\n")
    wc:add("new.txt")
    wc:delete("b.txt")
    wc:commit("Change a, add new, delete b\n\nWith a body line.")
    wc:update()
  end)

  after_each(function()
    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end

    if RevisionView.instance then
      RevisionView.instance:close()
    end

    util.reset_editor()

    -- Files of the working copy that were opened: the working copy is about to be removed
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.startswith(name, wc.path) or vim.startswith(name, "sven://") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    harness.cleanup()
  end)

  describe("the buffer", function()
    it("opens right away and fills in when the repository has answered", function()
      local view = RevisionView.new(3):open()

      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.is_true(RevisionView.is_open())
      assert.is_true(view.loading)
      assert.are.same({ "Revision 3", "", "Loading..." }, lines())

      assert.is_true(view:wait())
      assert.is_false(view.loading)
      assert.are.same("Revision 3", lines()[1])
      assert.is_true(#lines() > 10)
    end)

    it("shows who committed the revision, its message, what it changed and the diffs", function()
      open(3)

      local author = svn.log.revision(3).author
      local all = lines()

      assert.are.same("Revision 3", all[1])
      assert.are.same("Author:     " .. author, all[2])
      assert.is_truthy(all[3]:match("^Date:       %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %(.+ ago%)$"), all[3])

      assert.are.same({
        "",
        "Change a, add new, delete b",
        "",
        "With a body line.",
        "",
        "3 files changed, 3 insertions(+), 3 deletions(-)",
        "M /trunk/a.txt",
        "D /trunk/b.txt",
        "A /trunk/new.txt",
        "",
        "deleted b.txt",
        "@@ -1 +0,0 @@",
        "-hello",
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
        "added new.txt",
        "@@ -0,0 +1 @@",
        "+brand new",
      }, vim.list_slice(all, 4))

      assert.is_false(vim.bo.modifiable)
    end)

    it("takes the revision as a number or as text", function()
      for _, revision in ipairs { 3, "3", "r3" } do
        local view = open(revision)

        assert.are.same(3, view.revision)
        assert.are.same("3", RevisionView.current_oid())
        assert.are.same("Revision 3", lines()[1])
      end
    end)

    it("resolves a revision keyword", function()
      local view = open("HEAD")

      assert.are.same(3, view.revision)
      assert.are.same("3", RevisionView.current_oid())
      assert.are.same("Revision 3", lines()[1])
    end)

    it("folds files and hunks", function()
      open(3)

      goto_line("modified a.txt")
      assert.are.same(-1, vim.fn.foldclosed("."))

      feed("<tab>")
      local first = vim.fn.line(".")
      assert.are.same(first, vim.fn.foldclosed("."))
      -- The whole file is in the fold: header, two hunk headers and their lines
      assert.are.same(first + 15, vim.fn.foldclosedend("."))

      feed("<tab>")
      assert.are.same(-1, vim.fn.foldclosed("."))

      goto_line("@@ -15,6 +15,6 @@")
      feed("<tab>")
      assert.are.same(vim.fn.line("."), vim.fn.foldclosed("."))
      assert.are.same(vim.fn.line(".") + 7, vim.fn.foldclosedend("."))
    end)

    it("moves between hunk headers", function()
      open(3)
      goto_line("deleted b.txt")

      feed("}")
      assert.are.same("@@ -1 +0,0 @@", vim.api.nvim_get_current_line())
      feed("}")
      assert.are.same("modified a.txt", vim.api.nvim_get_current_line())
      feed("}")
      assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())
      feed("}")
      assert.are.same("@@ -15,6 +15,6 @@", vim.api.nvim_get_current_line())

      feed("{")
      assert.are.same("@@ -1,5 +1,5 @@", vim.api.nvim_get_current_line())
    end)

    it("says why a revision could not be loaded", function()
      local view = RevisionView.new(99):open()
      assert.is_true(view:wait())

      assert.are.same("Revision 99", lines()[1])
      assert.is_truthy(table.concat(lines(), "\n"):match("No such revision 99"))
      assert.is_nil(view.entry)
    end)

    it("names what the revision changed outside of the working copy", function()
      local note = wc.base .. "/note.txt"
      util.write_file(note, "a note\n")
      harness.svn(
        { "import", "-q", "-m", "Import a note", note, wc.repo_url .. "/branches/note.txt" },
        wc.path
      )

      open(4)

      assert.are.same({
        "1 file changed, 1 insertion(+)",
        "A /branches/note.txt",
        "",
        "added ^/branches/note.txt",
        "@@ -0,0 +1 @@",
        "+a note",
      }, vim.list_slice(lines(), 7))
    end)

    it("shows only the paths it is limited to", function()
      local view = open(3, { "a.txt" })

      assert.are.same({
        "1 file changed, 2 insertions(+), 2 deletions(-)",
        "M /trunk/a.txt",
        "",
        "Limited to a.txt",
        "",
        "modified a.txt",
        "@@ -1,5 +1,5 @@",
      }, vim.list_slice(lines(), 9, 15))
      assert.are.same(1, #view.diffs)
      assert.is_nil(table.concat(lines(), "\n"):find("b.txt", 1, true))
    end)

    it("accepts absolute paths and repository paths as limits", function()
      assert.are.same(
        { "new.txt" },
        vim.tbl_map(function(diff)
          return diff.file
        end, open(3, { wc:abs("new.txt") }).diffs)
      )

      assert.are.same(
        { "b.txt" },
        vim.tbl_map(function(diff)
          return diff.file
        end, open(3, { "^/trunk/b.txt" }).diffs)
      )
    end)

    it("shows everything when the limit matches nothing", function()
      local view = open(3, { "src/main.c" })

      assert.are.same(3, #view.diffs)
      assert.are.same({}, view.notes)
    end)

    it("closes", function()
      open(3)

      feed("q")

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype ~= "SvenRevisionView"
      end))
      assert.is_false(RevisionView.is_open())
      assert.is_nil(RevisionView.instance)
      assert.are.same("null-oid", RevisionView.current_oid())
    end)

    it("shows another revision in place", function()
      local view = open(3)
      local buffer = vim.api.nvim_get_current_buf()

      view:update(2)
      assert.are.same({ "Revision 2", "", "Loading..." }, lines())
      assert.is_true(view:wait())

      assert.are.same(buffer, vim.api.nvim_get_current_buf())
      assert.are.same("2", RevisionView.current_oid())
      assert.are.same("Add the initial files", lines()[5])
    end)

    it("yanks the revision", function()
      open(3)
      feed("Y")

      assert.are.same("r3", vim.fn.getreg('"'))
    end)

    it("opens the diff popup for the revision and the file under the cursor", function()
      open(3)
      goto_line("+line 2 changed")
      feed("d")

      assert.are.same("SvenPopup", vim.bo.filetype)

      local popup = require("sven.lib.popup").instance
      assert.are.same(3, popup.state.env.revision)
      assert.are.same({ "a.txt" }, popup.state.env.paths)
      assert.are.same("a.txt", popup.state.env.file)
    end)
  end)

  describe("opening or scrolling", function()
    it("opens next to the current window without taking the focus", function()
      local window = vim.api.nvim_get_current_win()

      RevisionView.open_or_scroll_down(3)

      assert.are.same(window, vim.api.nvim_get_current_win())
      assert.is_true(RevisionView.is_open())
      assert.are.same("3", RevisionView.current_oid())
      assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("scrolls the revision that is open", function()
      vim.o.lines = 20
      RevisionView.open_or_scroll_down("2")
      local view = RevisionView.instance
      assert.is_true(view:wait())

      local function top_line()
        return vim.fn.line("w0", view.buffer.win_handle)
      end

      assert.are.same(1, top_line())

      RevisionView.open_or_scroll_down(2)
      local scrolled = top_line()
      assert.is_true(scrolled > 1)
      assert.are.same(view, RevisionView.instance)

      RevisionView.open_or_scroll_up("r2")
      assert.is_true(top_line() < scrolled)
      assert.are.same(view, RevisionView.instance)

      vim.o.lines = 24
    end)

    it("shows another revision when asked for one", function()
      RevisionView.open_or_scroll_down(3)
      assert.is_true(RevisionView.instance:wait())

      RevisionView.open_or_scroll_down(2)
      assert.are.same("2", RevisionView.current_oid())
      assert.is_true(RevisionView.instance:wait())
      assert.are.same("Revision 2", lines(RevisionView.instance.buffer.handle)[1])
      assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
    end)
  end)

  describe("going to a file", function()
    it("opens the working file at the line of the hunk with <cr>", function()
      open(3)
      goto_line("+line 18 changed")

      feed("<cr>")

      wait_for_buffer("/a.txt")
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same(18, vim.fn.line("."))
      assert.are.same("line 18 changed", vim.api.nvim_get_current_line())
    end)

    it("opens the working file with the mapping of the revision view", function()
      open(3)
      goto_line(" line 4")

      feed("a")

      wait_for_buffer("/a.txt")
      assert.are.same(4, vim.fn.line("."))
    end)

    it("opens the working file from the header of a hunk and of a file", function()
      open(3)
      goto_line("@@ -15,6 +15,6 @@")
      feed("<cr>")

      wait_for_buffer("/a.txt")
      assert.are.same(15, vim.fn.line("."))

      open(3)
      goto_line("added new.txt")
      feed("<cr>")

      wait_for_buffer("/new.txt")
      assert.are.same(1, vim.fn.line("."))
    end)

    it("goes to the diff of a changed path with <cr>", function()
      open(3)
      goto_line("A /trunk/new.txt")

      feed("<cr>")

      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same("added new.txt", vim.api.nvim_get_current_line())
    end)

    it("opens the working file of a changed path with the mapping", function()
      open(3)
      goto_line("M /trunk/a.txt")

      feed("a")

      wait_for_buffer("/a.txt")
    end)

    it("shows a file that is gone from the working copy as it was", function()
      open(3)
      goto_line("-hello")

      feed("<cr>")

      wait_for_buffer("sven://r2/trunk/b.txt")
      assert.are.same({ "hello" }, lines())
      assert.is_false(vim.bo.modifiable)
      assert.are.same("nofile", vim.bo.buftype)
    end)

    it("says that a file is gone from the working copy when asked for the working file", function()
      open(3)
      goto_line("-hello")

      local notifications = util.capture_notifications(function()
        feed("a")
      end)

      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same(1, #notifications)
      assert.are.same("b.txt is not in the working copy", notifications[1].message)
      assert.are.same(vim.log.levels.WARN, notifications[1].level)
    end)
  end)

  describe("paths of the repository", function()
    it("knows where the working copy sits in the repository", function()
      assert.are.same("/trunk", svn.log.working_copy_prefix())
      assert.are.same("/trunk", svn.log.working_copy_prefix { cwd = wc.path })
    end)

    it("maps them to the working copy", function()
      local path = svn.log.working_copy_path

      assert.are.same("a.txt", path("/trunk/a.txt", "/trunk"))
      assert.are.same("src/sub/util.c", path("trunk/src/sub/util.c", "/trunk"))
      assert.are.same("a.txt", path("^/trunk/a.txt", "/trunk"))
      assert.are.same(".", path("/trunk", "/trunk"))

      -- Outside of it
      assert.is_nil(path("/branches/x/a.txt", "/trunk"))
      assert.is_nil(path("/trunk2/a.txt", "/trunk"))
      assert.is_nil(path("/", "/trunk"))

      -- A working copy of the repository root
      assert.are.same("trunk/a.txt", path("/trunk/a.txt", ""))
      assert.are.same(".", path("/", ""))

      -- Unknown
      assert.is_nil(path("/trunk/a.txt", nil))
    end)
  end)
end)
