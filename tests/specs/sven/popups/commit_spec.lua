local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

local STAGED = "sven-staged"

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

---@param filetype string
---@return integer|nil buf A buffer of that filetype shown in the current tab page
local function buffer_in_tab(filetype)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == filetype then
      return buf
    end
  end
end

describe("popups.commit", function()
  local wc
  local events
  local autocmd
  local input
  local original_get_permission

  ---What the user answers when asked for permission, and what they were asked
  local answer, questions

  ---@param env table|nil
  local function open_popup(env)
    wc:refresh()
    require("sven.popups.commit").create(env)
    assert.are.same("SvenPopup", vim.bo.filetype)
  end

  ---Waits for the commit editor and leaves insert mode
  local function wait_for_editor()
    assert.is_true(
      util.wait_for(function()
        return vim.bo.filetype == "gitcommit"
      end),
      "The commit editor did not open"
    )
    vim.cmd("stopinsert")
  end

  ---@param message string[]
  local function submit(message)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, message)
    feed("<c-c><c-c>")
  end

  ---@return boolean committed Whether a commit completed
  local function wait_for_commit()
    return util.wait_for(function()
      return #events > 0
    end, 10000)
  end

  ---Waits until the action of the popup has run to its end
  local function wait_for_action()
    local popup = require("sven.lib.popup")
    util.wait_for(function()
      return popup.__lock.permits > 0
    end, 10000)
  end

  ---@return string[] The comment block of the commit editor, from "Changes to be committed:" on
  local function listed_changes()
    local all = lines()
    for index, line in ipairs(all) do
      if line == "# Changes to be committed:" then
        return vim.list_slice(all, index)
      end
    end

    return {}
  end

  before_each(function()
    wc = harness.create()

    events = {}
    autocmd = vim.api.nvim_create_autocmd("User", {
      pattern = "SvenCommitComplete",
      callback = function(args)
        table.insert(events, args.data)
      end,
    })

    input = require("sven.lib.input")
    original_get_permission = input.get_permission
    answer, questions = true, {}
    input.get_permission = function(question)
      table.insert(questions, question)
      return answer
    end
  end)

  after_each(function()
    wait_for_action()
    input.get_permission = original_get_permission
    vim.api.nvim_del_autocmd(autocmd)

    util.reset_editor()
    harness.cleanup()
  end)

  describe("the popup", function()
    it("offers to commit what is staged, or everything", function()
      open_popup()

      assert.are.same({
        "Arguments",
        "-u Keep the locks of the committed files (--no-unlock)",
        "-k Keep the committed files in their changelists (--keep-changelists)",
        "-x Also commit file and directory externals (--include-externals)",
        "",
        "Create",
        "c Commit",
        "a Commit all changes",
      }, lines())
    end)

    it("offers to commit the file it was opened on", function()
      open_popup { paths = { "src/main.c" } }

      assert.are.same("f Commit main.c", lines()[9])
    end)

    it("offers to commit the files of a selection", function()
      open_popup { paths = { "a.txt", "b.txt" } }

      assert.are.same("f Commit 2 files", lines()[9])
    end)

    it("offers to commit the file of the buffer it was opened from", function()
      vim.cmd("edit " .. vim.fn.fnameescape(wc:abs("b.txt")))
      open_popup {}

      assert.are.same("f Commit b.txt", lines()[9])
    end)

    it("is what :Sven commit opens", function()
      vim.cmd("Sven commit cwd=" .. wc.path)

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "SvenPopup"
      end))
      assert.are.same("c Commit", lines()[7])
    end)
  end)

  describe("committing what is staged", function()
    before_each(function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "brand new\n")
      wc:add("new.txt")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist(STAGED, "a.txt", "new.txt")
    end)

    it("lists exactly what will be committed in the editor", function()
      open_popup()
      feed("c")
      wait_for_editor()

      assert.are.same({
        "",
        "",
        "#",
        "# Commands:",
        "#   q          Close",
        "#   <c-c><c-c> Submit",
        "#   <c-c><c-k> Abort",
        "#   <m-p>      Previous Message",
        "#   <m-n>      Next Message",
        "#   <m-r>      Reset Message",
        "#",
        "# Please enter the commit message for your changes. This comment block",
        "# is ignored, and an empty message aborts the commit.",
        "#",
        "# Changes to be committed:",
        "#   M a.txt",
        "#   A new.txt",
        "#",
      }, lines())

      feed("<c-c><c-k>")
    end)

    it("shows the diff of what will be committed next to the editor", function()
      open_popup()
      feed("c")
      wait_for_editor()

      local diff = buffer_in_tab("SvenDiffView")
      assert.is_not_nil(diff)
      assert.are.same({
        "Staged changes",
        "2 files changed, 2 insertions(+), 1 deletion(-)",
        "a.txt    |     2  +-",
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
        "added new.txt",
        "@@ -0,0 +1 @@",
        "+brand new",
      }, lines(diff))

      -- The editor is where the cursor is
      assert.are.same("gitcommit", vim.bo.filetype)

      feed("<c-c><c-k>")
      assert.is_true(util.wait_for(function()
        return buffer_in_tab("SvenDiffView") == nil and vim.bo.filetype ~= "gitcommit"
      end))
    end)

    it("does not show the diff when that is turned off", function()
      harness.setup { commit_editor = { show_staged_diff = false } }

      open_popup()
      feed("c")
      wait_for_editor()

      assert.is_nil(buffer_in_tab("SvenDiffView"))
      assert.are.same(1, #vim.api.nvim_tabpage_list_wins(0))

      feed("<c-c><c-k>")
    end)

    it("commits on submit, and says so", function()
      local notifications = util.capture_notifications(function()
        open_popup()
        feed("c")
        wait_for_editor()
        submit { "Change line 2 and add a file", "", "With a body." }

        assert.is_true(wait_for_commit())
      end)

      assert.are.same(3, wc:head())
      assert.are.same("Change line 2 and add a file\n\nWith a body.", wc:log_message(3))
      assert.are.same({ "A /trunk/new.txt", "M /trunk/a.txt" }, wc:changed_paths(3))

      -- What was not staged is still a local change, and nothing is staged anymore
      assert.are.same({ "M       b.txt" }, wc:status())
      assert.are.same({}, wc:members(STAGED))

      assert.are.same(1, #events)
      assert.are.same(3, events[1].revision)
      assert.are.same(wc.path, events[1].root)

      assert.are.same(1, #notifications)
      assert.are.same("Committed revision 3", notifications[1].message)
      assert.are.same(vim.log.levels.INFO, notifications[1].level)

      -- Editor and diff are gone
      assert.are_not.same("gitcommit", vim.bo.filetype)
      assert.is_nil(buffer_in_tab("SvenDiffView"))
    end)

    it("commits nothing when the editor is aborted", function()
      open_popup()
      feed("c")
      wait_for_editor()
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "Never mind" })
      feed("<c-c><c-k>")

      wait_for_action()

      assert.are.same(2, wc:head())
      assert.are.same({}, events)
      assert.are.same({ "a.txt", "new.txt" }, wc:members(STAGED))
    end)

    it("commits nothing when the message is empty", function()
      local notifications = util.capture_notifications(function()
        open_popup()
        feed("c")
        wait_for_editor()
        feed("<c-c><c-c>")

        wait_for_action()
      end)

      assert.are.same(2, wc:head())
      assert.are.same({}, events)
      assert.are.same("Aborting commit due to empty commit message", notifications[1].message)
    end)

    it("passes its switches on to svn", function()
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist("other", "src/main.c")

      open_popup()
      feed("-k")
      feed("a")
      wait_for_editor()

      assert.are.same({
        "# Changes to be committed:",
        "#   M a.txt",
        "#   M b.txt",
        "#   A new.txt",
        "#   M src/main.c",
        "#",
      }, listed_changes())

      submit { "Commit everything, keep the changelists" }
      assert.is_true(wait_for_commit())

      assert.are.same(3, wc:head())
      assert.are.same("", wc:status_of("src/main.c"))
      -- The changelist of the user is kept. The staging changelist is not: what is committed is
      -- not staged anymore.
      assert.are.same({ "src/main.c" }, wc:members("other"))
      assert.are.same({}, wc:members(STAGED))
    end)
  end)

  describe("with nothing staged", function()
    it("asks whether to commit everything", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")

      open_popup()
      feed("c")
      wait_for_editor()

      assert.are.same({ "Nothing staged. Commit all changes?" }, questions)
      assert.are.same({
        "# Changes to be committed:",
        "#   M a.txt",
        "#   M b.txt",
        "#",
      }, listed_changes())

      submit { "Commit all of it" }
      assert.is_true(wait_for_commit())

      assert.are.same(3, wc:head())
      assert.are.same({ "M /trunk/a.txt", "M /trunk/b.txt" }, wc:changed_paths(3))
      assert.are.same({}, wc:status())
    end)

    it("does nothing when the answer is no", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      answer = false

      open_popup()
      feed("c")
      wait_for_action()

      assert.are.same({ "Nothing staged. Commit all changes?" }, questions)
      assert.are_not.same("gitcommit", vim.bo.filetype)
      assert.are.same(2, wc:head())
      assert.are.same({ "M       a.txt" }, wc:status())
    end)

    it("says so when there is nothing to commit at all", function()
      wc:write("unversioned.txt", "not a change svn would commit\n")

      local notifications = util.capture_notifications(function()
        open_popup()
        feed("c")
        wait_for_action()
      end)

      assert.are.same({}, questions)
      assert.are.same(1, #notifications)
      assert.are.same("No changes to commit.", notifications[1].message)
      assert.are.same(vim.log.levels.WARN, notifications[1].level)
      assert.are_not.same("gitcommit", vim.bo.filetype)
    end)
  end)

  describe("committing everything", function()
    it("commits staged and unstaged changes of every changelist, but no unversioned files", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:delete("docs/readme.md")
      wc:write("unversioned.txt", "stays here\n")
      wc:changelist(STAGED, "a.txt")
      wc:changelist("other", "src/main.c")

      open_popup()
      feed("a")
      wait_for_editor()

      assert.are.same({}, questions)
      assert.are.same({
        "# Changes to be committed:",
        "#   M a.txt",
        "#   M b.txt",
        "#   D docs/readme.md",
        "#   M src/main.c",
        "#",
      }, listed_changes())

      local diff = buffer_in_tab("SvenDiffView")
      assert.is_not_nil(diff)
      assert.are.same("All changes", lines(diff)[1])
      assert.are.same("4 files changed, 3 insertions(+), 6 deletions(-)", lines(diff)[2])

      submit { "Commit everything" }
      assert.is_true(wait_for_commit())

      assert.are.same(3, wc:head())
      assert.are.same(
        { "D /trunk/docs/readme.md", "M /trunk/a.txt", "M /trunk/b.txt", "M /trunk/src/main.c" },
        wc:changed_paths(3)
      )
      assert.are.same({ "?       unversioned.txt" }, wc:status())
    end)

    it("refuses while a file is in conflict", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from elsewhere\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:update()

      local notifications = util.capture_notifications(function()
        open_popup()
        feed("a")
        wait_for_action()
      end)

      assert.are.same(1, #notifications)
      assert.are.same("Cannot commit: a.txt is in conflict. Resolve it first.", notifications[1].message)
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
      assert.are_not.same("gitcommit", vim.bo.filetype)
      assert.are.same(3, wc:head())
    end)
  end)

  describe("committing files", function()
    it("commits only the files it was opened on, staged or not", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:changelist(STAGED, "a.txt")

      open_popup { paths = { "b.txt", "src/main.c" } }
      feed("f")
      wait_for_editor()

      assert.are.same({
        "# Changes to be committed:",
        "#   M b.txt",
        "#   M src/main.c",
        "#",
      }, listed_changes())
      assert.are.same("Changes in 2 paths", lines(buffer_in_tab("SvenDiffView"))[1])

      submit { "Commit two files" }
      assert.is_true(wait_for_commit())

      assert.are.same({ "M /trunk/b.txt", "M /trunk/src/main.c" }, wc:changed_paths(3))
      -- What is staged stays staged
      assert.are.same({ "a.txt" }, wc:members(STAGED))
      assert.are.same("M", wc:status_of("a.txt"))
    end)

    it("commits a new file together with the new directory it is in", function()
      wc:write("newdir/inner.txt", "inner\n")
      wc:write("newdir/other.txt", "other\n")
      wc:add("newdir")

      open_popup { paths = { "newdir/inner.txt" } }
      feed("f")
      wait_for_editor()

      assert.are.same({
        "# Changes to be committed:",
        "#   A newdir",
        "#   A newdir/inner.txt",
        "#",
      }, listed_changes())

      submit { "Add one file of the new directory" }
      assert.is_true(wait_for_commit())

      assert.are.same({ "A /trunk/newdir", "A /trunk/newdir/inner.txt" }, wc:changed_paths(3))
      assert.are.same("A", wc:status_of("newdir/other.txt"))
    end)

    it("says so when the files have no changes", function()
      local notifications = util.capture_notifications(function()
        open_popup { paths = { "b.txt" } }
        feed("f")
        wait_for_action()
      end)

      assert.are.same(1, #notifications)
      assert.are.same("Cannot commit: There are no changes in b.txt", notifications[1].message)
      assert.are_not.same("gitcommit", vim.bo.filetype)
    end)
  end)

  describe("a commit that fails", function()
    it("keeps the message for the next attempt", function()
      local actions = require("sven.popups.commit.actions")

      -- Someone else changed the same file: the commit is refused as out of date
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from elsewhere\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:changelist(STAGED, "a.txt")

      local notifications = util.capture_notifications(function()
        open_popup()
        feed("c")
        wait_for_editor()
        submit { "A message worth keeping", "", "It took a while to write." }

        wait_for_action()
      end)

      assert.are.same({}, events)
      assert.are.same(3, wc:head())
      assert.are.same("Change line 5", wc:log_message(3))

      assert.are.same(2, #notifications)
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
      assert.is_truthy(
        notifications[1].message:match("out of date") or notifications[1].message:match("E160028")
      )
      assert.are.same(
        "Nothing was committed. Your message is kept: the next commit starts with it.",
        notifications[2].message
      )
      assert.are.same("A message worth keeping\n\nIt took a while to write.", actions.kept_message())

      -- The next commit starts with it
      open_popup()
      feed("c")
      wait_for_editor()

      assert.are.same(
        { "A message worth keeping", "", "It took a while to write.", "", "#" },
        vim.list_slice(lines(), 1, 5)
      )

      feed("<c-c><c-k>")
      wait_for_action()

      -- An aborted attempt does not lose it
      assert.are.same("A message worth keeping\n\nIt took a while to write.", actions.kept_message())

      -- It is forgotten once a commit went through
      wc:update()
      wc:svn("resolve", "--accept", "working", "a.txt")
      wc:changelist(STAGED, "a.txt")

      open_popup()
      feed("c")
      wait_for_editor()
      feed("<c-c><c-c>")
      assert.is_true(wait_for_commit())

      assert.are.same("A message worth keeping\n\nIt took a while to write.", wc:log_message(4))
      assert.is_nil(actions.kept_message())
    end)
  end)

  describe("#comments", function()
    local actions

    before_each(function()
      actions = require("sven.popups.commit.actions")
    end)

    it("lists the letters of svn status", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:delete("b.txt")
      wc:write("new.txt", "new\n")
      wc:add("new.txt")

      local plan = assert(require("sven.lib.svn").commit.plan("all"))

      assert.are.same({
        "Changes to be committed:",
        "  M a.txt",
        "  D b.txt",
        "  A new.txt",
      }, actions.comments(plan))
    end)

    it("has a column for properties when properties changed", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:propset("svn:eol-style", "native", "b.txt")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:propset("svn:keywords", "Id", "src/main.c")

      local plan = assert(require("sven.lib.svn").commit.plan("all"))

      assert.are.same({
        "Changes to be committed:",
        "  M  a.txt",
        "   M b.txt",
        "  MM src/main.c",
      }, actions.comments(plan))
    end)
  end)

  describe("the plan of a commit", function()
    local commit

    ---@param plan SvenCommitPlan
    ---@return string[]
    local function names(plan)
      return vim.tbl_map(function(item)
        return item.name
      end, plan.items)
    end

    before_each(function()
      commit = require("sven.lib.svn").commit

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:write("newdir/inner.txt", "inner\n")
      wc:add("newdir")
      wc:write("unversioned.txt", "not part of any commit\n")
      wc:changelist(STAGED, "a.txt", "newdir/inner.txt")
    end)

    it("names what is staged, and the new directories that have to come along", function()
      local plan = assert(commit.plan("staged"))

      assert.are.same("staged", plan.kind)
      assert.are.same({ "a.txt", "newdir", "newdir/inner.txt" }, plan.targets)
      assert.are.same({ "a.txt", "newdir", "newdir/inner.txt" }, names(plan))
    end)

    it("names every change for a commit of everything", function()
      local plan = assert(commit.plan("all"))

      assert.are.same("all", plan.kind)
      assert.is_nil(plan.targets)
      assert.are.same({ "a.txt", "b.txt", "newdir", "newdir/inner.txt" }, names(plan))
    end)

    it("names the changes of the paths that are asked for", function()
      local plan = assert(commit.plan("paths", { wc:abs("b.txt"), "newdir" }))

      assert.are.same("paths", plan.kind)
      assert.are.same({ "b.txt", "newdir" }, plan.paths)
      assert.are.same({ "b.txt", "newdir", "newdir/inner.txt" }, plan.targets)
      assert.are.same({ "b.txt", "newdir", "newdir/inner.txt" }, names(plan))
    end)

    it("says why there is no plan", function()
      wc:svn("changelist", "--remove", "--depth", "infinity", ".")

      assert.are.same({ nil, "Nothing is staged" }, { commit.plan("staged") })
      assert.are.same({ nil, "No paths given" }, { commit.plan("paths", {}) })
      assert.are.same({ nil, "There are no changes in src" }, { commit.plan("paths", { "src" }) })

      wc:svn("revert", "-q", "-R", ".")
      assert.are.same({ nil, "No changes to commit" }, { commit.plan("all") })
    end)

    it("commits nothing itself, and is what run commits", function()
      local plan = assert(commit.plan("staged"))
      assert.are.same(2, wc:head())

      local revision = commit.run(plan, "Commit the plan")

      assert.are.same(3, revision)
      assert.are.same(
        { "A /trunk/newdir", "A /trunk/newdir/inner.txt", "M /trunk/a.txt" },
        wc:changed_paths(3)
      )
      assert.are.same("M", wc:status_of("b.txt"))
    end)
  end)
end)
