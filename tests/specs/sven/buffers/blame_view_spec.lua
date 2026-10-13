local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@param buf integer|nil
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

---@param buf integer
---@param row integer One-based
---@return string[] groups The highlight groups on a row of the gutter, sorted
---@return boolean shaded Whether the row is shaded
local function highlights(buf, row)
  local groups = {}
  local shaded = false

  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true }))
  do
    if mark[4].hl_group then
      table.insert(groups, mark[4].hl_group)
    end
    if mark[4].line_hl_group == "SvenBlameShade" then
      shaded = true
    end
  end

  table.sort(groups)

  return groups, shaded
end

describe("buffers.blame_view", function()
  local wc
  local Blame

  ---What the gutter shows for a committed line: revision, author and date
  ---@param revision integer
  ---@return string
  local function row(revision)
    local entry = require("sven.lib.svn").log.list({ revision = revision })[1]
    local date = require("sven.lib.svn.date")

    return ("r%d %s %s"):format(revision, entry.author, date.format(date.parse(entry.date), "%Y-%m-%d"))
  end

  ---Opens a blame and waits for it
  ---@param path string|nil
  ---@param opts table|nil
  ---@return SvenBlameView
  local function open(path, opts)
    local blame = assert(Blame.open(path, opts), "The blame did not open")
    assert.is_true(Blame.wait(blame), "The blame did not load")

    return blame
  end

  ---@param relative string
  local function edit(relative)
    vim.cmd("edit " .. vim.fn.fnameescape(wc:abs(relative)))
  end

  before_each(function()
    wc = harness.create()
    Blame = require("sven.buffers.blame_view")

    -- r3 changes line 2 and lines 10 and 11 of a.txt
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:replace("a.txt", "line 10\nline 11\n", "line 10 changed\nline 11 changed\n")
    wc:commit("Change three lines")
    wc:update()
  end)

  after_each(function()
    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local blame = Blame.get(buf)
      if blame then
        Blame.close(blame)
      end
    end

    util.reset_editor()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.startswith(name, wc.path) or vim.startswith(name, "sven") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    harness.cleanup()
  end)

  describe("the gutter", function()
    it("opens to the left of the file, with a row for every line", function()
      edit("a.txt")
      local file_window = vim.api.nvim_get_current_win()

      local blame = open()

      assert.are.same({ blame.gutter_win, file_window }, vim.api.nvim_tabpage_list_wins(0))
      assert.are.same(file_window, blame.file_win)
      assert.are.same(file_window, vim.api.nvim_get_current_win())
      assert.are.same(wc:abs("a.txt"), blame.path)
      assert.are.same("a.txt", blame.relative)

      assert.are.same("SvenBlame", vim.bo[blame.gutter_buf].filetype)
      assert.are.same("nofile", vim.bo[blame.gutter_buf].buftype)
      assert.is_false(vim.bo[blame.gutter_buf].modifiable)

      local r2, r3 = row(2), row(3)
      assert.are.same({
        r2,
        r3,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
        r3,
        r3,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
        r2,
      }, lines(blame.gutter_buf))

      -- Just wide enough
      assert.are.same(#r2 + 1, vim.api.nvim_win_get_width(blame.gutter_win))
      assert.is_true(vim.wo[blame.gutter_win].winfixwidth)
    end)

    it("is there right away and fills in when svn has answered", function()
      edit("a.txt")
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      local blame = assert(Blame.open())

      assert.is_true(blame.loading)
      assert.is_nil(blame.lines)
      assert.are.same(20, #lines(blame.gutter_buf))
      assert.are.same("Loading...", lines(blame.gutter_buf)[1])
      assert.are.same("Loading...", lines(blame.gutter_buf)[5])
      assert.are.same("", lines(blame.gutter_buf)[2])

      assert.is_true(Blame.wait(blame))
      assert.is_false(blame.loading)
      assert.are.same(20, #blame.lines)
      assert.are.same(row(2), lines(blame.gutter_buf)[1])
    end)

    it("marks lines that are not committed", function()
      wc:replace("a.txt", "line 5\n", "line 5 changed locally\n")
      wc:append("a.txt", "a new line\n")
      edit("a.txt")

      local blame = open()
      local rows = lines(blame.gutter_buf)

      assert.are.same(21, #rows)
      assert.are.same(row(2), rows[4])
      assert.are.same("   uncommitted", rows[5])
      assert.are.same(row(2), rows[6])
      assert.are.same("   uncommitted", rows[21])

      assert.are.same({ "SvenBlameUncommitted" }, (highlights(blame.gutter_buf, 5)))
    end)

    it("highlights revision, author and date, and shades every other block", function()
      edit("a.txt")
      local blame = open()

      assert.are.same(
        { "SvenBlameAuthor", "SvenBlameDate", "SvenBlameRevision" },
        (highlights(blame.gutter_buf, 1))
      )

      -- Blocks: line 1 (r2), line 2 (r3), lines 3 to 9 (r2), lines 10 and 11 (r3), the rest (r2)
      local shaded = {}
      for line = 1, 20 do
        local _, is_shaded = highlights(blame.gutter_buf, line)
        if is_shaded then
          table.insert(shaded, line)
        end
      end

      assert.are.same({ 2, 10, 11 }, shaded)
    end)

    it("binds scrolling and the cursor of the two windows", function()
      edit("a.txt")
      vim.wo.wrap = true

      local blame = open()

      for _, win in ipairs { blame.gutter_win, blame.file_win } do
        assert.is_true(vim.wo[win].scrollbind)
        assert.is_true(vim.wo[win].cursorbind)
        assert.is_false(vim.wo[win].wrap)
      end

      feed("15G")
      assert.are.same({ 15, 0 }, vim.api.nvim_win_get_cursor(blame.file_win))
      assert.are.same({ 15, 0 }, vim.api.nvim_win_get_cursor(blame.gutter_win))

      feed("<c-e><c-e>")
      assert.are.same(3, vim.fn.line("w0", blame.file_win))
      assert.are.same(3, vim.fn.line("w0", blame.gutter_win))

      -- And the other way round
      vim.api.nvim_set_current_win(blame.gutter_win)
      feed("gg")
      assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(blame.file_win))
      assert.are.same(1, vim.fn.line("w0", blame.file_win))
    end)

    it("starts where the file window is", function()
      vim.o.lines = 14
      edit("a.txt")
      feed("G")
      local top = vim.fn.line("w0")
      assert.is_true(top > 1)

      local blame = open()

      assert.are.same(top, vim.fn.line("w0", blame.gutter_win))
      assert.are.same({ 20, 0 }, vim.api.nvim_win_get_cursor(blame.gutter_win))

      vim.o.lines = 24
    end)

    it("blames what is written when the file is written", function()
      edit("a.txt")
      local blame = open()
      assert.are.same(20, #lines(blame.gutter_buf))

      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "a new first line" })
      vim.cmd("silent write")

      assert.is_true(util.wait_for(function()
        return lines(blame.gutter_buf)[1] == "   uncommitted"
      end))
      assert.are.same(21, #lines(blame.gutter_buf))
      assert.are.same(row(2), lines(blame.gutter_buf)[2])

      -- And every time after that, not just once
      vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
      vim.cmd("silent write")

      assert.is_true(util.wait_for(function()
        return #lines(blame.gutter_buf) == 20 and lines(blame.gutter_buf)[1] == row(2)
      end))

      vim.api.nvim_buf_set_lines(0, -1, -1, false, { "a new last line" })
      vim.cmd("silent write")

      assert.is_true(util.wait_for(function()
        return lines(blame.gutter_buf)[21] == "   uncommitted"
      end))
    end)

    it("is shaded again after the colorscheme changed, every time", function()
      edit("a.txt")
      open()

      for _ = 1, 2 do
        -- What a colorscheme that defines every group from scratch leaves of it
        vim.api.nvim_set_hl(0, "SvenBlameShade", {})
        assert.is_nil(vim.api.nvim_get_hl(0, { name = "SvenBlameShade" }).link)

        vim.api.nvim_exec_autocmds("ColorScheme", {})
        assert.are.same("CursorLine", vim.api.nvim_get_hl(0, { name = "SvenBlameShade" }).link)
      end
    end)
  end)

  describe("opening", function()
    it("takes a path relative to the working copy root", function()
      local blame = open("src/main.c")

      assert.are.same(wc:abs("src/main.c"), vim.api.nvim_buf_get_name(0))
      assert.are.same(wc:abs("src/main.c"), blame.path)
      assert.are.same("src/main.c", blame.relative)
      assert.are.same({ row(2), row(2), row(2), row(2), row(2) }, lines(blame.gutter_buf))
    end)

    it("takes an absolute path", function()
      local blame = open(wc:abs("src/sub/util.c"))

      assert.are.same("src/sub/util.c", blame.relative)
      assert.are.same(wc.path, blame.root)
      assert.are.same(3, #lines(blame.gutter_buf))
    end)

    it("copes with names that mean something to svn and to the shell", function()
      wc:write("my docs/icon@2x.txt", "one\ntwo\n")
      wc:add("my docs")
      wc:commit("Add a file with an awkward name")

      local blame = open("my docs/icon@2x.txt")

      assert.are.same(wc:abs("my docs/icon@2x.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same({ row(4), row(4) }, lines(blame.gutter_buf))

      -- And as it was in a revision
      Blame.close(blame)
      local earlier = open("my docs/icon@2x.txt", { revision = 4 })

      assert.are.same("sven://r4/my docs/icon@2x.txt", vim.api.nvim_buf_get_name(earlier.file_buf))
      assert.are.same({ "one", "two" }, lines(earlier.file_buf))
      assert.are.same({ row(4), row(4) }, lines(earlier.gutter_buf))
    end)

    it("finds the working copy of a file on its own", function()
      -- Another working copy than the current one
      local other = wc:checkout()
      wc:use()

      local blame = open(other:abs("b.txt"))

      assert.are.same(other.path, blame.root)
      assert.are.same({ row(2) }, lines(blame.gutter_buf))
    end)

    it("is what :Sven blame does", function()
      edit("a.txt")
      vim.cmd("Sven blame")

      local blame = assert(Blame.get())
      assert.are.same("a.txt", blame.relative)
      Blame.close(blame)

      vim.cmd("Sven blame " .. vim.fn.fnameescape(wc:abs("b.txt")))
      blame = assert(Blame.get())
      assert.are.same("b.txt", blame.relative)
    end)

    it("completes the subcommand and its file", function()
      assert.are.same({ "blame" }, vim.fn.getcompletion("Sven bl", "cmdline"))
      assert.is_true(vim.tbl_contains(vim.fn.getcompletion("Sven ", "cmdline"), "blame"))

      local files = vim.fn.getcompletion("Sven blame " .. wc.path .. "/a", "cmdline")
      assert.are.same({ wc.path .. "/a.txt" }, files)
    end)

    it("toggles off when the file is blamed already", function()
      edit("a.txt")
      vim.wo.wrap = true
      local file_window = vim.api.nvim_get_current_win()

      local blame = open()
      assert.is_true(Blame.is_open())

      assert.is_nil(Blame.open(wc:abs("a.txt")))

      assert.is_true(blame.closed)
      assert.is_false(Blame.is_open())
      assert.are.same({ file_window }, vim.api.nvim_tabpage_list_wins(0))
      assert.is_false(vim.wo[file_window].scrollbind)
      assert.is_false(vim.wo[file_window].cursorbind)
      assert.is_true(vim.wo[file_window].wrap)
    end)

    it("toggles off from the gutter", function()
      edit("a.txt")
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      assert.is_nil(Blame.open())

      assert.is_true(blame.closed)
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("says why a file cannot be blamed", function()
      wc:write("new.txt", "not known to svn\n")

      local blame
      local notifications = util.capture_notifications(function()
        blame = assert(Blame.open("new.txt"))
        Blame.wait(blame)
      end)

      assert.is_true(blame.closed)
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("^Unable to blame new.txt\n"))
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("says that a binary file cannot be blamed", function()
      wc:write("image.bin", "a\0b\0c")
      wc:add("image.bin")
      wc:commit("Add a binary file")

      local blame
      local notifications = util.capture_notifications(function()
        blame = assert(Blame.open("image.bin"))
        Blame.wait(blame)
      end)

      assert.is_true(blame.closed)
      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("binary"))
    end)

    it("refuses files outside of a working copy", function()
      local dir = util.create_temp_dir()
      util.write_file(dir .. "/file.txt", "text\n")

      local notifications = util.capture_notifications(function()
        assert.is_nil(Blame.open(dir .. "/file.txt"))
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("is not inside a Subversion working copy"))

      vim.fn.delete(dir, "rf")
    end)
  end)

  describe("in the gutter", function()
    it("opens the revision of a line with <cr>", function()
      edit("a.txt")
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      vim.api.nvim_win_set_cursor(0, { 10, 0 })
      feed("<cr>")

      local RevisionView = require("sven.buffers.revision_view")
      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same("3", RevisionView.current_oid())
      assert.are.same({ "a.txt" }, RevisionView.instance.item_filter)

      -- In a tab of its own: the blame is untouched
      assert.are.same(2, #vim.api.nvim_list_tabpages())
      assert.is_false(blame.closed)
      assert.is_true(vim.api.nvim_win_is_valid(blame.gutter_win))

      assert.is_true(RevisionView.instance:wait())
      RevisionView.instance:close()
    end)

    it("has no revision to open for a line that is not committed", function()
      wc:append("a.txt", "a new line\n")
      edit("a.txt")
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      vim.api.nvim_win_set_cursor(0, { 21, 0 })

      local notifications = util.capture_notifications(function()
        feed("<cr>")
      end)

      assert.are.same("This line is not committed yet", notifications[1].message)
      assert.are.same("SvenBlame", vim.bo.filetype)
    end)

    it("closes with q and gives the file window its options back", function()
      edit("a.txt")
      vim.wo.wrap = true
      local file_window = vim.api.nvim_get_current_win()
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      feed("q")

      assert.is_true(blame.closed)
      assert.is_false(vim.api.nvim_win_is_valid(blame.gutter_win))
      assert.is_false(vim.api.nvim_buf_is_valid(blame.gutter_buf))
      assert.are.same({ file_window }, vim.api.nvim_tabpage_list_wins(0))
      assert.are.same(file_window, vim.api.nvim_get_current_win())
      assert.is_false(vim.wo[file_window].scrollbind)
      assert.is_false(vim.wo[file_window].cursorbind)
      assert.is_true(vim.wo[file_window].wrap)
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
    end)

    it("yanks the revision of a line", function()
      edit("a.txt")
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      feed("Y")

      assert.are.same("r3", vim.fn.getreg('"'))
    end)

    it("opens the diff popup for the revision of a line and the file", function()
      edit("a.txt")
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      feed("d")

      assert.are.same("SvenPopup", vim.bo.filetype)

      local popup = require("sven.lib.popup").instance
      assert.are.same(3, popup.state.env.revision)
      assert.are.same("a.txt", popup.state.env.file)
    end)

    it("blames the file as it was before the revision of a line with -", function()
      edit("a.txt")
      local file_buffer = vim.api.nvim_get_current_buf()
      local file_window = vim.api.nvim_get_current_win()
      local blame = open()

      vim.api.nvim_set_current_win(blame.gutter_win)
      vim.api.nvim_win_set_cursor(0, { 10, 0 })
      feed("-")

      -- The file of r2 takes the place of the working file
      assert.is_true(util.wait_for(function()
        return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_window)) == "sven://r2/a.txt"
      end))

      local earlier = assert(Blame.get(vim.api.nvim_win_get_buf(file_window)))
      assert.is_true(Blame.wait(earlier))

      assert.is_true(blame.closed)
      assert.are.same(2, earlier.revision)
      assert.are.same("line 10", lines(earlier.file_buf)[10])
      assert.are.same(row(2), lines(earlier.gutter_buf)[10])
      assert.are.same({ 10, 0 }, vim.api.nvim_win_get_cursor(file_window))
      assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))

      -- Closing it brings the working file back
      vim.api.nvim_set_current_win(earlier.gutter_win)
      feed("q")

      assert.are.same({ file_window }, vim.api.nvim_tabpage_list_wins(0))
      assert.are.same(file_buffer, vim.api.nvim_win_get_buf(file_window))
      assert.is_false(vim.wo[file_window].scrollbind)
    end)
  end)

  describe("closing a window", function()
    it("of the gutter leaves the file as it was", function()
      edit("a.txt")
      local file_window = vim.api.nvim_get_current_win()
      local blame = open()

      vim.api.nvim_win_close(blame.gutter_win, true)

      assert.is_true(util.wait_for(function()
        return blame.closed
      end))
      assert.are.same({ file_window }, vim.api.nvim_tabpage_list_wins(0))
      assert.is_false(vim.wo[file_window].scrollbind)
      assert.is_false(vim.wo[file_window].cursorbind)
      assert.is_false(Blame.is_open(vim.api.nvim_win_get_buf(file_window)))
    end)

    it("of the file takes the gutter along", function()
      vim.cmd("split")
      edit("a.txt")
      local blame = open()
      assert.are.same(3, #vim.api.nvim_tabpage_list_wins(0))

      vim.api.nvim_win_close(blame.file_win, true)

      assert.is_true(util.wait_for(function()
        return blame.closed and not vim.api.nvim_win_is_valid(blame.gutter_win)
      end))
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("ends the blame when the window shows another file", function()
      edit("a.txt")
      local blame = open()

      edit("b.txt")

      assert.is_true(util.wait_for(function()
        return blame.closed
      end))
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
      assert.is_false(vim.wo.scrollbind)
    end)
  end)

  describe("of a revision", function()
    it("shows the file as it was, with its blame", function()
      edit("b.txt")
      local previous = vim.api.nvim_get_current_buf()

      local blame = open("a.txt", { revision = "r2" })

      assert.are.same(2, blame.revision)
      assert.are.same("sven://r2/a.txt", vim.api.nvim_buf_get_name(blame.file_buf))
      assert.are.same(blame.file_buf, vim.api.nvim_get_current_buf())
      assert.is_false(vim.bo.modifiable)
      assert.are.same("line 2", lines()[2])
      assert.are.same(20, #lines(blame.gutter_buf))
      assert.are.same(row(2), lines(blame.gutter_buf)[2])

      -- q in the file ends it as well, and brings back what the window showed
      feed("q")

      assert.is_true(blame.closed)
      assert.are.same(previous, vim.api.nvim_get_current_buf())
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("is what :Sven blame does with a revision", function()
      vim.cmd("Sven blame " .. vim.fn.fnameescape(wc:abs("a.txt")) .. " revision=2")

      assert.is_true(util.wait_for(function()
        return vim.api.nvim_buf_get_name(0) == "sven://r2/a.txt"
      end))
      assert.are.same(2, Blame.get().revision)
    end)

    it("says so when the file was not there", function()
      local blame
      local notifications = util.capture_notifications(function()
        blame = assert(Blame.open("a.txt", { revision = 1 }))
        Blame.wait(blame)
      end)

      assert.is_true(blame.closed)
      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("^Unable to read a.txt at r1\n"))
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))
    end)
  end)

  describe("#format", function()
    it("lines the columns up", function()
      local rows, marks, shaded = Blame.format({
        { line = 1, revision = 9, author = "al", date = "2026-01-02T12:00:00.000000Z" },
        { line = 2, revision = 9, author = "al", date = "2026-01-02T12:00:00.000000Z" },
        { line = 3, revision = 120, author = "barbara", date = "2026-03-04T12:00:00.000000Z" },
        { line = 4 },
        { line = 5 },
        { line = 6, revision = 9, author = "al", date = "2026-01-02T12:00:00.000000Z" },
      }, 7)

      assert.are.same({
        "  r9 al      2026-01-02",
        "  r9 al      2026-01-02",
        "r120 barbara 2026-03-04",
        "     uncommitted",
        "     uncommitted",
        "  r9 al      2026-01-02",
        "",
      }, rows)

      -- Blocks 2 (r120) and 4 (r9 again) are shaded
      assert.are.same({ 2, 5 }, shaded)

      assert.are.same({ 0, 0, 4, "SvenBlameRevision" }, marks[1])
      assert.are.same({ 0, 5, 12, "SvenBlameAuthor" }, marks[2])
      assert.are.same({ 0, 13, 23, "SvenBlameDate" }, marks[3])
      assert.are.same({ 3, 5, 16, "SvenBlameUncommitted" }, marks[10])
    end)

    it("cuts long author names short", function()
      local rows = Blame.format({
        { line = 1, revision = 1, author = ("x"):rep(30), date = "2026-01-02T12:00:00.000000Z" },
      }, 1)

      assert.are.same("r1 " .. ("x"):rep(20) .. " 2026-01-02", rows[1])
    end)
  end)
end)
