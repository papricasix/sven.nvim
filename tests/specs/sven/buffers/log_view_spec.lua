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

---@return string[] The lines that are not hidden in a closed fold
local function visible_lines()
  local result = {}
  local all = lines()

  local line = 1
  while line <= #all do
    table.insert(result, all[line])

    local fold_end = vim.fn.foldclosedend(line)
    line = (fold_end == -1 and line or fold_end) + 1
  end

  return result
end

---@param line integer
---@return string The virtual text at the right edge of a line
local function virtual_text(line)
  local text = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(0, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true }))
  do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      table.insert(text, chunk[1])
    end
  end

  return table.concat(text)
end

describe("buffers.log_view", function()
  local wc
  local svn
  local LogView
  local RevisionView

  ---@param opts SvenLogOpts|nil
  ---@param view_opts table|nil
  ---@return SvenLogView
  local function open(opts, view_opts)
    local entries = svn.log.list(vim.tbl_extend("force", { verbose = true }, opts or {}))

    local view = LogView.new(vim.tbl_extend("force", {
      entries = entries,
      header = "Revisions in ^/trunk",
    }, view_opts or {}))
    view:open()

    return view
  end

  before_each(function()
    wc = harness.create()
    svn = require("sven.lib.svn")
    LogView = require("sven.buffers.log_view")
    RevisionView = require("sven.buffers.revision_view")

    -- r3 changes, adds and deletes; r4 to r6 each append a line to a.txt
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:write("new.txt", "brand new\n")
    wc:add("new.txt")
    wc:delete("b.txt")
    wc:commit("Change a, add new, delete b\n\nWith a body line.")
    for i = 1, 3 do
      wc:append("a.txt", "more " .. i .. "\n")
      wc:commit("Append " .. i)
    end
    wc:update()
  end)

  after_each(function()
    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end

    util.reset_editor()
    harness.cleanup()
  end)

  it("shows one row per revision, newest first", function()
    local view = open()

    assert.are.same("SvenLogView", vim.bo.filetype)
    assert.is_true(LogView.is_open())
    assert.is_false(vim.bo.modifiable)

    assert.are.same({
      "",
      "r6  Append 3",
      "r5  Append 2",
      "r4  Append 1",
      "r3  Change a, add new, delete b",
      "r2  Add the initial files",
      "r1  Create the layout",
    }, visible_lines())

    -- Author and date are at the right edge
    local author = svn.log.list({ limit = 1 })[1].author
    assert.is_truthy(virtual_text(2):find(author, 1, true))
    assert.is_truthy(virtual_text(2):match("seconds? ago") or virtual_text(2):match("minutes? ago"))

    -- The cursor starts on the newest revision
    assert.are.same(2, vim.fn.line("."))
    assert.are.same(6, view:revision_under_cursor())
  end)

  it("names what the log is of in its header", function()
    local view = open()

    local header = vim.api.nvim_win_get_buf(view.buffer.header_win_handle)
    assert.are.same({ " Revisions in ^/trunk" }, vim.api.nvim_buf_get_lines(header, 0, -1, false))
  end)

  it("unfolds a row to the whole message and the changed paths", function()
    open()

    -- r3 is the fourth row
    feed("jjj")
    assert.are.same("r3  Change a, add new, delete b", vim.api.nvim_get_current_line())
    assert.are_not.same(-1, vim.fn.foldclosed("."))

    feed("<tab>")
    assert.are.same(-1, vim.fn.foldclosed("."))

    local first = vim.fn.line(".")
    local author = svn.log.list({ limit = 1 })[1].author
    local details = vim.list_slice(lines(), first, first + 10)

    assert.are.same("r3  Change a, add new, delete b", details[1])
    assert.are.same("   Author: " .. author, details[2])
    assert.is_truthy(details[3]:match("^   Date:   %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"))
    assert.are.same({
      "",
      "   Change a, add new, delete b",
      "",
      "   With a body line.",
      "",
      "   M /trunk/a.txt",
      "   D /trunk/b.txt",
      "   A /trunk/new.txt",
    }, vim.list_slice(details, 4, 11))

    -- j moves on to the next revision, not into the details
    feed("j")
    assert.are.same("r2  Add the initial files", vim.api.nvim_get_current_line())

    feed("k")
    feed("<tab>")
    assert.are_not.same(-1, vim.fn.foldclosed("."))
  end)

  it("lists the source of a copy with the changed paths", function()
    wc:svn("copy", "a.txt", "copy.txt")
    wc:commit("Copy a file")
    wc:update()

    open { limit = 1 }
    feed("<tab>")

    assert.are.same("   A /trunk/copy.txt (from /trunk/a.txt:6)", lines()[8])
  end)

  it("opens the revision under the cursor in the revision view", function()
    open()
    feed("jjj")
    feed("<cr>")

    assert.are.same("SvenRevisionView", vim.bo.filetype)
    assert.is_true(RevisionView.is_open())
    assert.are.same("3", RevisionView.current_oid())

    assert.is_true(RevisionView.instance:wait())
    assert.are.same("Revision 3", lines()[1])
    assert.are.same("3 files changed, 2 insertions(+), 2 deletions(-)", lines()[9])
  end)

  it("shows a revision next to the log and scrolls it", function()
    local view = open()
    local log_window = vim.api.nvim_get_current_win()

    feed("]c")

    -- The focus stays in the log
    assert.are.same(log_window, vim.api.nvim_get_current_win())
    assert.is_true(RevisionView.is_open())
    assert.are.same("6", RevisionView.current_oid())
    assert.is_true(RevisionView.instance:wait())

    -- Moving on with the revision view open shows the next revision in it
    feed("<c-j>")
    assert.are.same(5, view:revision_under_cursor())
    assert.are.same("5", RevisionView.current_oid())
    assert.is_true(RevisionView.instance:wait())
    assert.are.same("Revision 5", lines(RevisionView.instance.buffer.handle)[1])

    -- The first of the two closes the revision view, the second the log
    feed("q")
    assert.is_true(util.wait_for(function()
      return not RevisionView.is_open()
    end))
    assert.is_true(LogView.is_open())

    feed("q")
    assert.is_true(util.wait_for(function()
      return not LogView.is_open()
    end))
  end)

  it("limits the revision view to the files the log is of", function()
    open({ path = "a.txt" }, { header = "Revisions of a.txt", files = { "a.txt" } })

    assert.are.same({
      "",
      "r6  Append 3",
      "r5  Append 2",
      "r4  Append 1",
      "r3  Change a, add new, delete b",
      "r2  Add the initial files",
    }, visible_lines())

    feed("jjj")
    feed("<cr>")
    assert.is_true(RevisionView.instance:wait())

    assert.are.same({
      "1 file changed, 1 insertion(+), 1 deletion(-)",
      "M /trunk/a.txt",
      "",
      "Limited to a.txt",
      "",
      "modified a.txt",
    }, vim.list_slice(lines(), 9, 14))
  end)

  it("yanks the revision under the cursor", function()
    open()
    feed("j")
    feed("Y")

    assert.are.same("r5", vim.fn.getreg('"'))
  end)

  it("makes its working copy the current one whenever it is entered", function()
    local other = wc:checkout()
    wc:use()

    local view = open()
    local log_window = vim.api.nvim_get_current_win()
    vim.cmd("vsplit | enew")
    local elsewhere = vim.api.nvim_get_current_win()

    -- Not just the first time: the revision view and the diff buffer rely on the same hook
    for _ = 1, 3 do
      vim.api.nvim_set_current_win(elsewhere)
      other:use()
      assert.are.same(other.path, svn.repo.root)

      vim.api.nvim_set_current_win(log_window)
      assert.are.same(wc.path, svn.repo.root)
      assert.are.same(wc.path, view.root)
    end
  end)

  it("opens the diff popup for the revision under the cursor", function()
    open()
    feed("j")
    feed("d")

    assert.are.same("SvenPopup", vim.bo.filetype)

    local popup = require("sven.lib.popup").instance
    assert.are.same(5, popup.state.env.revision)
    assert.are.same({}, popup.state.env.paths)
    assert.is_truthy(table.concat(lines(), "\n"):find("d r5", 1, true))
  end)

  it("opens the diff popup for a range of selected revisions", function()
    open()
    feed("jVjj")
    feed("d")

    assert.are.same("SvenPopup", vim.bo.filetype)

    local popup = require("sven.lib.popup").instance
    assert.are.same({ 3, 5 }, popup.state.env.range)
    assert.are.same(5, popup.state.env.revision)
  end)

  describe("loading more", function()
    ---Opens a log that is fetched in pages, the way the log popup does it
    ---@param arguments string[]
    local function open_paged(arguments)
      require("sven").action("log", "log_current", arguments)()

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "SvenLogView"
      end))
    end

    ---Presses + and waits for the history that is loaded
    ---@param expected integer Number of revisions shown afterwards
    local function load_more(expected)
      feed("+")
      assert.is_true(
        util.wait_for(function()
          return #LogView.instance.entries == expected
        end),
        ("Expected %d revisions, got %d"):format(expected, #LogView.instance.entries)
      )
    end

    it("says that there is more, and appends it", function()
      open_paged { "--limit=2", "--verbose" }

      assert.are.same({
        "",
        "r6  Append 3",
        "r5  Append 2",
        "Type + to show more history",
      }, visible_lines())

      load_more(4)
      assert.are.same({
        "",
        "r6  Append 3",
        "r5  Append 2",
        "r4  Append 1",
        "r3  Change a, add new, delete b",
        "Type + to show more history",
      }, visible_lines())

      load_more(6)
      assert.are.same("Type + to show more history", visible_lines()[8])

      -- Asking again finds that there is nothing left
      local notifications = util.capture_notifications(function()
        feed("+")
        util.wait_for(function()
          return not LogView.instance.has_more
        end)
      end)

      assert.are.same({
        "",
        "r6  Append 3",
        "r5  Append 2",
        "r4  Append 1",
        "r3  Change a, add new, delete b",
        "r2  Add the initial files",
        "r1  Create the layout",
      }, visible_lines())
      assert.are.same("There is no more history", notifications[1].message)

      notifications = util.capture_notifications(function()
        feed("+")
      end)
      assert.are.same("There is no more history", notifications[1].message)
    end)

    it("does not offer more when everything fits", function()
      open_paged { "--limit=50" }

      assert.are.same("r1  Create the layout", visible_lines()[7])
      assert.are.same(7, #visible_lines())
      assert.is_false(LogView.instance.has_more)
    end)

    it("stays inside the range that was asked for", function()
      open_paged { "--limit=2", "--revision=5:2" }

      assert.are.same({ "", "r5  Append 2", "r4  Append 1", "Type + to show more history" }, visible_lines())

      load_more(4)
      assert.are.same("r2  Add the initial files", visible_lines()[5])

      feed("+")
      assert.is_true(util.wait_for(function()
        return not LogView.instance.has_more
      end))
      assert.are.same(4, #LogView.instance.entries)
    end)

    it("searches further back when a search is active", function()
      -- svn applies the limit before it searches: of the newest two revisions one matches
      open_paged { "--limit=2", "--search=Append [13]" }

      assert.are.same({ "", "r6  Append 3", "Type + to show more history" }, visible_lines())

      load_more(2)
      assert.are.same({ "", "r6  Append 3", "r4  Append 1", "Type + to show more history" }, visible_lines())
    end)
  end)
end)
