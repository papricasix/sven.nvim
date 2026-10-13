local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

local STAGED = "sven-staged"

-- The fork of unified.nvim that sven integrates with: UNIFIED_DIR, or a checkout next to this
-- repository. The specs that need it are skipped when it is not there.
local UNIFIED = os.getenv("UNIFIED_DIR") or vim.fs.normalize(vim.fn.getcwd() .. "/../unified.nvim")

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

---Forgets unified.nvim, as if it was never installed
local function unload_unified()
  vim.opt.runtimepath:remove(UNIFIED)

  for name, _ in pairs(package.loaded) do
    if name == "unified" or vim.startswith(name, "unified.") then
      package.loaded[name] = nil
    end
  end
end

describe("popups.diff", function()
  local wc
  local inline
  local input
  local original_get_user_input

  ---What the user types when asked for input, and what they were asked with
  local typed, prompts

  ---@param env table|nil
  ---@return PopupData
  local function open_popup(env)
    wc:refresh()
    local popup = require("sven.popups.diff").create(env)
    assert.are.same("SvenPopup", vim.bo.filetype)

    return popup
  end

  ---Waits until the action of the popup has run to its end
  local function wait_for_action()
    local popup = require("sven.lib.popup")
    util.wait_for(function()
      return popup.__lock.permits > 0
    end, 10000)
  end

  ---Opens the popup, presses a key and waits for the action to finish
  ---@param env table|nil
  ---@param key string
  local function run(env, key)
    open_popup(env)
    feed(key)
    wait_for_action()
  end

  ---Waits for the diff buffer an action opens
  local function wait_for_diff()
    assert.is_true(
      util.wait_for(function()
        return vim.bo.filetype == "SvenDiffView"
      end, 10000),
      "The diff buffer did not open"
    )
  end

  ---@param relative string
  local function edit(relative)
    vim.cmd("edit " .. vim.fn.fnameescape(wc:abs(relative)))
  end

  before_each(function()
    unload_unified()

    wc = harness.create()
    inline = require("sven.buffers.diff.inline")

    input = require("sven.lib.input")
    original_get_user_input = input.get_user_input
    typed, prompts = nil, {}
    input.get_user_input = function(prompt, opts)
      table.insert(prompts, { prompt = prompt, default = opts and opts.default })
      return typed
    end
  end)

  after_each(function()
    wait_for_action()
    input.get_user_input = original_get_user_input

    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end

    inline.clear_all()

    local RevisionView = require("sven.buffers.revision_view")
    if RevisionView.instance then
      RevisionView.instance:close()
    end

    util.reset_editor()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.startswith(name, wc.path) or vim.startswith(name, "sven://") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    harness.cleanup()
    unload_unified()
  end)

  describe("the popup", function()
    it("offers the diffs", function()
      open_popup()

      assert.are.same({
        "Arguments",
        "-w Ignore whitespace (--extensions=-w)",
        "-p Ignore property changes (--ignore-properties)",
        "",
        "Diff                Revisions",
        "d working copy      r revision",
        "w working copy      R range",
        "s staged",
      }, lines())
    end)

    it("names what its first action is going to show", function()
      ---@param env table
      ---@return string
      local function this(env)
        open_popup(env)
        return lines()[6]:match("^d (.-)%s%s")
      end

      assert.are.same("main.c", this { paths = { "src/main.c" } })
      assert.are.same("2 paths", this { paths = { "a.txt", "b.txt" } })
      assert.are.same("r3", this { revision = 3 })
      assert.are.same("r3 of a.txt", this { revision = 3, paths = { "a.txt" } })
      assert.are.same("staged", this { section = { name = "staged" } })
      assert.are.same("working copy", this { section = { name = "changes" } })
    end)

    it("names the file of the buffer it was opened from", function()
      edit("b.txt")
      open_popup {}

      assert.are.same("d b.txt", lines()[6]:match("^d %S+"))
    end)

    it("offers what a revision did to a file when there is a file", function()
      open_popup { paths = { "a.txt" } }

      assert.are.same("w working copy      f file in revision", lines()[7])
      assert.are.same("s staged            R range", lines()[8])
    end)

    it("is what :Sven diff opens", function()
      vim.cmd("Sven diff cwd=" .. wc.path)

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "SvenPopup"
      end))
      assert.are.same("s staged", lines()[8])
    end)
  end)

  describe("without unified.nvim", function()
    it("has no inline diffs to offer", function()
      assert.is_false(inline.available())
      assert.is_false(inline.show(vim.api.nvim_get_current_buf(), "base"))
    end)

    it("shows the changes of the file it was opened on in the diff buffer", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      run({ paths = { "a.txt" } }, "d")
      wait_for_diff()

      assert.are.same({
        "Changes in a.txt",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "a.txt  |     2  +-",
        "",
        "modified a.txt",
        "@@ -1,5 +1,5 @@",
        " line 1",
        "-line 2",
        "+line 2 changed",
        " line 3",
        " line 4",
        " line 5",
      }, lines())

      -- In a tab of its own
      assert.are.same(2, #vim.api.nvim_list_tabpages())
    end)

    it("shows the changes of the file of the buffer it was opened from", function()
      wc:replace("src/main.c", "return 0", "return 1")
      edit("src/main.c")

      run({}, "d")
      wait_for_diff()

      assert.are.same("Changes in src/main.c", lines()[1])
      assert.are.same("modified src/main.c", lines()[5])
    end)

    it("shows an unversioned file as added", function()
      wc:write("new.txt", "one\ntwo\n")

      run({ paths = { "new.txt" } }, "d")
      wait_for_diff()

      assert.are.same({
        "Changes in new.txt",
        "1 file changed, 2 insertions(+)",
        "new.txt  |     2  ++",
        "",
        "unversioned new.txt",
        "@@ -0,0 +1,2 @@",
        "+one",
        "+two",
      }, lines())
    end)

    it("shows a file that is scheduled for addition as added", function()
      wc:write("new.txt", "one\n")
      wc:add("new.txt")

      run({ paths = { "new.txt" } }, "d")
      wait_for_diff()

      assert.are.same({ "added new.txt", "@@ -0,0 +1 @@", "+one" }, vim.list_slice(lines(), 5))
    end)

    it("shows a deleted file as removed", function()
      wc:delete("b.txt")

      run({ paths = { "b.txt" } }, "d")
      wait_for_diff()

      assert.are.same({ "deleted b.txt", "@@ -1 +0,0 @@", "-hello" }, vim.list_slice(lines(), 5))
    end)

    it("shows a missing file as removed", function()
      wc:remove("b.txt")

      run({ paths = { "b.txt" } }, "d")
      wait_for_diff()

      assert.are.same({ "missing b.txt", "@@ -1 +0,0 @@", "-hello" }, vim.list_slice(lines(), 5))
    end)

    it("says that a binary file cannot be shown", function()
      wc:write("image.bin", "a\0b\0c")

      run({ paths = { "image.bin" } }, "d")
      wait_for_diff()

      assert.are.same(
        { "unversioned image.bin", "Cannot display: file looks like a binary." },
        vim.list_slice(lines(), 5)
      )
    end)

    it("shows everything below a directory", function()
      wc:replace("src/main.c", "return 0", "return 1")
      wc:replace("src/sub/util.c", "a + b", "b + a")
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      run({ paths = { "src" } }, "d")
      wait_for_diff()

      assert.are.same({
        "Changes in src",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "src/main.c      |     2  +-",
        "src/sub/util.c  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("shows the changes of several paths", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")

      run({ paths = { "a.txt", "b.txt" } }, "d")
      wait_for_diff()

      assert.are.same({
        "Changes in 2 paths",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "a.txt  |     2  +-",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("says so when a file has no changes", function()
      local notifications = util.capture_notifications(function()
        run({ paths = { "a.txt" } }, "d")
      end)

      assert.are_not.same("SvenDiffView", vim.bo.filetype)
      assert.are.same(1, #notifications)
      assert.are.same("a.txt has no local changes", notifications[1].message)
    end)

    it("shows a revision in the revision view", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:commit("Change a")
      wc:update()

      run({ revision = 3 }, "d")

      local RevisionView = require("sven.buffers.revision_view")
      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same("3", RevisionView.current_oid())
      assert.is_nil(RevisionView.instance.item_filter)
      assert.is_true(RevisionView.instance:wait())
    end)

    it("shows what a revision did to a file in the diff buffer", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:commit("Change a and b")
      wc:update()

      run({ revision = 3, paths = { "a.txt" } }, "d")
      wait_for_diff()

      assert.are.same({
        "r3: a.txt",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "a.txt  |     2  +-",
        "",
        "modified a.txt",
        "@@ -1,5 +1,5 @@",
      }, vim.list_slice(lines(), 1, 6))
    end)

    it("shows all changes of the working copy without a file", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      run({}, "d")
      wait_for_diff()

      assert.are.same({
        "Changes in the working copy",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "a.txt  |     2  +-",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("shows what is staged from the staged section", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist(STAGED, "b.txt")

      run({ section = { name = "staged" } }, "d")
      wait_for_diff()

      assert.are.same({
        "Staged changes",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 3))
    end)
  end)

  describe("its other diffs", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:commit("Change a")
      wc:replace("b.txt", "hello", "bye")
      wc:commit("Change b")
      wc:update()
    end)

    it("shows all changes of the working copy", function()
      wc:replace("a.txt", "line 3\n", "line 3 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGED, "a.txt")

      run({ paths = { "a.txt" } }, "w")
      wait_for_diff()

      assert.are.same({
        "Changes in the working copy",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "a.txt       |     2  +-",
        "src/main.c  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("shows what is staged", function()
      wc:replace("a.txt", "line 3\n", "line 3 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGED, "a.txt")

      run({}, "s")
      wait_for_diff()

      assert.are.same({
        "Staged changes",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "a.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 3))
    end)

    it("says so when nothing is staged", function()
      local notifications = util.capture_notifications(function()
        run({}, "s")
      end)

      assert.are.same("Nothing is staged", notifications[1].message)
      assert.are_not.same("SvenDiffView", vim.bo.filetype)
    end)

    it("ignores whitespace when told to", function()
      wc:replace("a.txt", "line 3\n", "line   3\n")
      wc:replace("b.txt", "bye", "goodbye")

      open_popup()
      feed("-w")
      feed("w")
      wait_for_action()
      wait_for_diff()

      assert.are.same({
        "Changes in the working copy",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 3))
    end)

    it("asks for a revision and shows it in the revision view", function()
      typed = "r3"

      run({}, "r")

      local RevisionView = require("sven.buffers.revision_view")
      assert.are.same({ { prompt = "Revision", default = "HEAD" } }, prompts)
      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same("3", RevisionView.current_oid())
    end)

    it("offers the revision under the cursor when asking for one", function()
      typed = "4"

      run({ revision = 4 }, "r")

      assert.are.same("4", prompts[1].default)
      assert.are.same("4", require("sven.buffers.revision_view").current_oid())
    end)

    it("shows no revision when none is given", function()
      typed = nil

      run({}, "r")

      assert.are_not.same("SvenRevisionView", vim.bo.filetype)
    end)

    it("asks for a range and shows the difference in the diff buffer", function()
      typed = "r2:r4"

      run({}, "R")
      wait_for_diff()

      assert.are.same("BASE:HEAD", prompts[1].default)
      assert.are.same({
        "Changes 2:4 in the working copy",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "a.txt  |     2  +-",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("limits a range to the file it was opened on", function()
      typed = "2:4"

      run({ paths = { "b.txt" } }, "R")
      wait_for_diff()

      assert.are.same({
        "Changes 2:4 in b.txt",
        "1 file changed, 1 insertion(+), 1 deletion(-)",
        "b.txt  |     2  +-",
      }, vim.list_slice(lines(), 1, 3))
    end)

    it("offers the change of the revision under the cursor as range", function()
      typed = "2:3"
      run({ revision = 3 }, "R")
      assert.are.same("2:3", prompts[1].default)
    end)

    it("offers the selected revisions as range", function()
      typed = "2:4"
      run({ revision = 4, range = { 3, 4 } }, "R")
      assert.are.same("2:4", prompts[1].default)
    end)

    it("compares a revision with the working copy", function()
      wc:replace("src/main.c", "return 0", "return 1")
      typed = "3"

      run({}, "R")
      wait_for_diff()

      -- What r4 did, and what is not committed
      assert.are.same({
        "Changes 3 in the working copy",
        "2 files changed, 2 insertions(+), 2 deletions(-)",
        "b.txt       |     2  +-",
        "src/main.c  |     2  +-",
      }, vim.list_slice(lines(), 1, 4))
    end)

    it("asks for the revision of a file, offering its last change", function()
      typed = "3"

      run({ paths = { "a.txt" } }, "f")
      wait_for_diff()

      assert.are.same({ { prompt = "Revision of a.txt", default = "3" } }, prompts)
      assert.are.same("r3: a.txt", lines()[1])
    end)

    it("shows the revision view for a file that is not in the revision", function()
      typed = "1"

      run({ paths = { "a.txt" } }, "f")

      local RevisionView = require("sven.buffers.revision_view")
      assert.are.same("SvenRevisionView", vim.bo.filetype)
      assert.are.same("1", RevisionView.current_oid())
      assert.are.same({ "a.txt" }, RevisionView.instance.item_filter)
    end)
  end)

  describe("with unified.nvim", function()
    local namespace

    ---@param buf integer|nil
    ---@return table[] The marks unified.nvim drew in a buffer
    local function marks(buf)
      return vim.api.nvim_buf_get_extmarks(buf or 0, namespace, 0, -1, { details = true })
    end

    ---@param buf integer|nil
    ---@return integer[] lines The lines (one-based) that are marked as added
    ---@return string[] deleted The deleted lines that are shown as virtual lines
    local function drawn(buf)
      local added, deleted = {}, {}

      for _, mark in ipairs(marks(buf)) do
        local details = mark[4]
        if details.hl_group == "UnifiedDiffAdd" then
          table.insert(added, mark[2] + 1)
        end

        for _, virtual_line in ipairs(details.virt_lines or {}) do
          local text = {}
          for _, chunk in ipairs(virtual_line) do
            table.insert(text, chunk[1])
          end
          table.insert(deleted, (table.concat(text):gsub("%s+$", "")))
        end
      end

      table.sort(added)

      return added, deleted
    end

    if vim.fn.isdirectory(UNIFIED) ~= 1 then
      pending("is not installed at " .. UNIFIED, function() end)
      return
    end

    before_each(function()
      vim.opt.runtimepath:prepend(UNIFIED)
      assert.is_true(inline.available())
      namespace = require("unified.config").ns_id
    end)

    it("draws the changes of a file into the file itself", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("a.txt", "line 18\n", "line 18\nline 18b\n")
      local window = vim.api.nvim_get_current_win()

      run({ paths = { "a.txt" } }, "d")

      -- The working file, in an ordinary window: no diff buffer, no new tab
      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same(window, vim.api.nvim_get_current_win())
      assert.are.same(1, #vim.api.nvim_list_tabpages())
      assert.are.same("", vim.bo.buftype)
      assert.is_true(vim.bo.modifiable)

      assert.is_true(inline.is_shown())
      local added, deleted = drawn()
      assert.are.same({ 2, 19 }, added)
      assert.are.same({ "line 2" }, deleted)

      -- The cursor is on the first change
      assert.are.same(2, vim.fn.line("."))
    end)

    it("draws the changes of the file of the buffer it was opened from", function()
      wc:replace("src/main.c", "return 0", "return 1")
      edit("src/main.c")
      local buffer = vim.api.nvim_get_current_buf()

      run({}, "d")

      assert.are.same(buffer, vim.api.nvim_get_current_buf())
      assert.is_true(inline.is_shown(buffer))
      assert.are.same({ 4 }, (drawn()))
    end)

    it("copes with names that mean something to svn and to the shell", function()
      wc:write("my docs/icon@2x.txt", "one\ntwo\n")
      wc:add("my docs")
      wc:commit("Add a file with an awkward name")
      wc:replace("my docs/icon@2x.txt", "two", "three")

      run({ paths = { "my docs/icon@2x.txt" } }, "d")

      assert.are.same(wc:abs("my docs/icon@2x.txt"), vim.api.nvim_buf_get_name(0))
      local added, deleted = drawn()
      assert.are.same({ 2 }, added)
      assert.are.same({ "two" }, deleted)

      -- And in a revision
      run({ revision = 3, paths = { "my docs/icon@2x.txt" } }, "d")

      assert.are.same("sven://r3/my docs/icon@2x.txt", vim.api.nvim_buf_get_name(0))
      assert.are.same({ 1, 2 }, (drawn()))
    end)

    it("removes the inline diff when asked for it again", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      run({ paths = { "a.txt" } }, "d")
      local buffer = vim.api.nvim_get_current_buf()
      assert.is_true(#marks(buffer) > 0)

      local notifications = util.capture_notifications(function()
        run({ paths = { "a.txt" } }, "d")
      end)

      assert.is_false(inline.is_shown(buffer))
      assert.are.same({}, marks(buffer))
      assert.are.same("Inline diff of a.txt cleared", notifications[1].message)

      -- And draws it again the time after
      run({ paths = { "a.txt" } }, "d")
      assert.is_true(inline.is_shown(buffer))
      assert.is_true(#marks(buffer) > 0)
    end)

    it("offers to clear the inline diffs it shows", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      open_popup { paths = { "a.txt" } }
      assert.is_nil(table.concat(lines(), "\n"):find("x clear", 1, true))
      feed("d")
      wait_for_action()
      run({ paths = { "b.txt" } }, "d")
      assert.are.same(2, #inline.buffers())

      open_popup()
      assert.is_truthy(table.concat(lines(), "\n"):find("x clear", 1, true))

      local notifications = util.capture_notifications(function()
        feed("x")
        wait_for_action()
      end)

      assert.are.same({}, inline.buffers())
      assert.are.same("2 inline diffs cleared", notifications[1].message)
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        assert.are.same({}, marks(buf))
      end
    end)

    it("keeps the inline diff up to date while the file is edited", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      run({ paths = { "a.txt" } }, "d")
      assert.are.same({ 2 }, (drawn()))

      vim.api.nvim_buf_set_lines(0, 4, 5, false, { "line 5 edited" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })

      local added, deleted = drawn()
      assert.are.same({ 2, 5 }, added)
      assert.are.same({ "line 2", "line 5" }, deleted)

      -- Back to the base text: nothing left to draw, but it keeps watching
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "line 2" })
      vim.api.nvim_buf_set_lines(0, 4, 5, false, { "line 5" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
      assert.are.same({}, marks())
      assert.is_true(inline.is_shown())

      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "line 1 edited" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
      assert.are.same({ 1 }, (drawn()))
    end)

    it("does not draw again what was reset with unified.nvim", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      run({ paths = { "a.txt" } }, "d")
      local buffer = vim.api.nvim_get_current_buf()

      -- What `:Unified reset` does to a buffer
      vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
      vim.api.nvim_buf_set_lines(buffer, 4, 5, false, { "line 5 edited" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buffer })

      assert.are.same({}, marks(buffer))
      assert.is_false(inline.is_shown(buffer))
    end)

    it("follows the base text when the file is committed", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      run({ paths = { "a.txt" } }, "d")
      local buffer = vim.api.nvim_get_current_buf()
      assert.is_true(#marks(buffer) > 0)

      wc:commit("Change a")
      require("sven.lib.event").send("CommitComplete", { revision = 3 })

      assert.is_true(util.wait_for(function()
        return #marks(buffer) == 0
      end))
      assert.is_true(inline.is_shown(buffer))

      -- With every commit, not just with the first one
      vim.api.nvim_buf_set_lines(buffer, 4, 5, false, { "line 5 edited" })
      vim.cmd("silent write")
      assert.are.same({ 5 }, (drawn(buffer)))

      wc:commit("Change a again")
      require("sven.lib.event").send("CommitComplete", { revision = 4 })

      assert.is_true(util.wait_for(function()
        return #marks(buffer) == 0
      end))

      -- The same goes for an update
      local other = wc:checkout()
      other:replace("a.txt", "line 9\n", "line 9 from elsewhere\n")
      other:commit("Change line 9")
      vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "line 1 edited" })
      vim.cmd("silent write")
      wc:update()
      vim.cmd("silent checktime")
      assert.are.same("line 9 from elsewhere", vim.api.nvim_buf_get_lines(buffer, 8, 9, false)[1])
      require("sven.lib.event").send("UpdateComplete", {})

      -- Only the local change is left: what the update brought is in the base text now
      assert.is_true(util.wait_for(function()
        local added, deleted = drawn(buffer)
        return vim.deep_equal(added, { 1 }) and vim.deep_equal(deleted, { "line 1" })
      end))

      -- Reading the file again takes the marks along, but not the diff
      vim.cmd("silent edit!")
      assert.is_true(inline.is_shown(buffer))
      assert.are.same({ 1 }, (drawn(buffer)))
    end)

    it("draws an unversioned file as added", function()
      wc:write("new.txt", "one\ntwo\n")

      run({ paths = { "new.txt" } }, "d")

      assert.are.same(wc:abs("new.txt"), vim.api.nvim_buf_get_name(0))
      local added, deleted = drawn()
      assert.are.same({ 1, 2 }, added)
      assert.are.same({}, deleted)
    end)

    it("draws a file that is scheduled for addition as added", function()
      wc:write("new.txt", "one\n")
      wc:add("new.txt")

      run({ paths = { "new.txt" } }, "d")

      assert.are.same(wc:abs("new.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same({ 1 }, (drawn()))
    end)

    it("shows a deleted file in the diff buffer", function()
      wc:delete("b.txt")

      run({ paths = { "b.txt" } }, "d")
      wait_for_diff()

      assert.are.same({ "deleted b.txt", "@@ -1 +0,0 @@", "-hello" }, vim.list_slice(lines(), 5))
    end)

    it("says that a binary file cannot be shown", function()
      wc:write("image.bin", "a\0b\0c")
      wc:add("image.bin")
      local buffer = vim.api.nvim_get_current_buf()

      local notifications = util.capture_notifications(function()
        run({ paths = { "image.bin" } }, "d")
      end)

      assert.are.same(buffer, vim.api.nvim_get_current_buf())
      assert.are.same(1, #notifications)
      assert.are.same("image.bin is a binary file: there is no diff to show", notifications[1].message)
      assert.are.same(vim.log.levels.WARN, notifications[1].level)
    end)

    it("says so when a file has no changes", function()
      local notifications = util.capture_notifications(function()
        run({ paths = { "a.txt" } }, "d")
      end)

      assert.are.same(wc:abs("a.txt"), vim.api.nvim_buf_get_name(0))
      assert.are.same({}, marks())
      assert.are.same("a.txt has no local changes", notifications[1].message)
    end)

    it("still shows several paths in the diff buffer", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      run({ paths = { "a.txt", "b.txt" } }, "d")
      wait_for_diff()

      assert.are.same("Changes in 2 paths", lines()[1])
    end)

    describe("and a revision", function()
      before_each(function()
        wc:replace("src/main.c", "return 0", "return 1")
        wc:write("new.c", "int one(void) {\n  return 1;\n}\n")
        wc:add("new.c")
        wc:delete("b.txt")
        wc:commit("Return one, add a file, delete a file")
        wc:replace("src/main.c", "return 1", "return 2")
        wc:commit("Return two")
        wc:update()
      end)

      it("shows the file as it was in the revision, with what the revision changed", function()
        edit("a.txt")
        local previous = vim.api.nvim_get_current_buf()

        run({ revision = 3, paths = { "src/main.c" } }, "d")

        assert.are.same("sven://r3/src/main.c", vim.api.nvim_buf_get_name(0))
        assert.are.same("c", vim.bo.filetype)
        assert.are.same("nofile", vim.bo.buftype)
        assert.is_false(vim.bo.modifiable)
        assert.is_true(vim.bo.readonly)

        -- The text of r3, not the one of the working copy
        assert.are.same({ "#include <stdio.h>", "", "int main(void) {", "  return 1;", "}" }, lines())

        local added, deleted = drawn()
        assert.are.same({ 4 }, added)
        assert.are.same({ "  return 0;" }, deleted)
        assert.are.same("r2", inline.get().label)

        -- q puts back what the window showed
        feed("q")
        assert.are.same(previous, vim.api.nvim_get_current_buf())
      end)

      it("shows a file that the revision added as all new", function()
        run({ revision = 3, paths = { "new.c" } }, "d")

        assert.are.same("sven://r3/new.c", vim.api.nvim_buf_get_name(0))
        local added, deleted = drawn()
        assert.are.same({ 1, 2, 3 }, added)
        assert.are.same({}, deleted)
      end)

      it("asks for the revision of a file", function()
        typed = "4"

        run({ paths = { "src/main.c" } }, "f")

        assert.are.same({ { prompt = "Revision of src/main.c", default = "4" } }, prompts)
        assert.are.same("sven://r4/src/main.c", vim.api.nvim_buf_get_name(0))
        assert.are.same("  return 2;", lines()[4])

        local added, deleted = drawn()
        assert.are.same({ 4 }, added)
        assert.are.same({ "  return 1;" }, deleted)
      end)

      it("says so when the revision did not change the file", function()
        local notifications = util.capture_notifications(function()
          run({ revision = 4, paths = { "new.c" } }, "d")
        end)

        assert.are.same("sven://r4/new.c", vim.api.nvim_buf_get_name(0))
        assert.are.same({}, marks())
        assert.are.same("r4 did not change the text of new.c", notifications[1].message)
      end)

      it("shows the revision view for a file the revision removed", function()
        wc:write("b.txt", "back again\n")

        run({ revision = 3, paths = { "b.txt" } }, "d")

        local RevisionView = require("sven.buffers.revision_view")
        assert.are.same("SvenRevisionView", vim.bo.filetype)
        assert.are.same("3", RevisionView.current_oid())
        assert.are.same({ "b.txt" }, RevisionView.instance.item_filter)
      end)

      it("still shows a whole revision in the revision view", function()
        run({ revision = 3 }, "d")

        assert.are.same("SvenRevisionView", vim.bo.filetype)
      end)
    end)
  end)
end)
