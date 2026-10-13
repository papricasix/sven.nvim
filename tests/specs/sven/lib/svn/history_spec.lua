local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local svn = require("sven.lib.svn")
local date = require("sven.lib.svn.date")

---@param entries SvenLogEntry[]
---@return number[]
local function revisions(entries)
  return vim.tbl_map(function(entry)
    return entry.revision
  end, entries)
end

describe("lib.svn.date", function()
  it("parses the timestamps svn prints", function()
    assert.are.same(0, date.parse("1970-01-01T00:00:00.000000Z"))
    assert.are.same(86400, date.parse("1970-01-02T00:00:00.000000Z"))
    assert.are.same(951782400, date.parse("2000-02-29T00:00:00.000000Z"))
    assert.are.same(1791837104, date.parse("2026-10-12T20:31:44.107693Z"))
  end)

  it("returns nil for anything else", function()
    assert.is_nil(date.parse(nil))
    assert.is_nil(date.parse(""))
    assert.is_nil(date.parse("yesterday"))
  end)

  it("formats relative dates", function()
    local now = 1791837104

    assert.are.same("5 seconds ago", date.relative(now - 5, now))
    assert.are.same("1 second ago", date.relative(now - 1, now))
    assert.are.same("5 minutes ago", date.relative(now - 5 * 60, now))
    assert.are.same("3 hours ago", date.relative(now - 3 * 3600, now))
    assert.are.same("2 days ago", date.relative(now - 2 * 86400, now))
    assert.are.same("3 weeks ago", date.relative(now - 21 * 86400, now))
    assert.are.same("4 months ago", date.relative(now - 120 * 86400, now))
    assert.are.same("1 year, 2 months ago", date.relative(now - 425 * 86400, now))
    assert.are.same("2 years ago", date.relative(now - 730 * 86400, now))
    assert.are.same("10 years ago", date.relative(now - 3650 * 86400, now))
    assert.are.same("", date.relative(nil, now))
  end)
end)

describe("lib.svn history", function()
  local wc

  ---Three more revisions on top of the two the harness creates:
  ---  3  a.txt line 2 changed, new.txt added
  ---  4  b.txt deleted, a.txt copied to copy.txt
  ---  5  a.txt line 19 changed
  local function make_history()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:write("new.txt", "new\n")
    wc:add("new.txt")
    wc:commit(table.concat({
      "Change line 2 and add new.txt",
      "",
      "With a body that has <angle brackets> & an ampersand.",
      "And a second body line.",
    }, "\n"))

    wc:delete("b.txt")
    wc:svn("copy", "a.txt", "copy.txt")
    wc:commit("Delete b.txt, copy a.txt")

    wc:replace("a.txt", "line 19\n", "line 19 changed\n")
    wc:commit("Change line 19")
  end

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  describe("log", function()
    before_each(make_history)

    it("lists the newest revisions first, including those newer than the working copy", function()
      -- The root of the working copy is still at revision 2
      assert.are.same(2, svn.info.get().revision)

      assert.are.same({ 5, 4, 3, 2, 1 }, revisions(svn.log.list()))
    end)

    it("describes an entry", function()
      local entry = svn.log.list({ revision = 3 })[1]

      assert.are.same(3, entry.revision)
      assert.are.same(vim.env.USER, entry.author)
      assert.is_truthy(entry.date:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+Z$"))
      assert.are.same("Change line 2 and add new.txt", entry.subject)
      assert.are.same(
        "Change line 2 and add new.txt\n\nWith a body that has <angle brackets> & an ampersand.\nAnd a second body line.",
        entry.message
      )
      assert.are.same(
        "With a body that has <angle brackets> & an ampersand.\nAnd a second body line.",
        entry.body
      )
      assert.are.same(4, #entry.description)
      assert.are.same({}, entry.paths)
    end)

    it("carries the fields Neogit's commit components read", function()
      local entry = svn.log.list({ revision = 3 })[1]

      assert.are.same("3", entry.oid)
      assert.are.same("r3", entry.abbreviated_commit)
      assert.are.same(entry.author, entry.author_name)
      assert.are.same(entry.author, entry.committer_name)
      assert.are.same("", entry.author_email)
      assert.are.same("", entry.ref_name)
      assert.is_truthy(entry.rel_date:match(" ago$"))
      assert.is_truthy(entry.author_date:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"))
      assert.is_truthy(entry.log_date:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$"))
      assert.is_true(math.abs(os.time() - entry.unix_date) < 3600)
    end)

    it("limits the number of entries", function()
      assert.are.same({ 5, 4 }, revisions(svn.log.list { limit = 2 }))
    end)

    it("includes the changed paths when asked to", function()
      local entries = svn.log.list { revision = "4:3", verbose = true }

      assert.are.same(2, #entries)
      assert.are.same(4, entries[1].revision)

      local by_path = {}
      for _, path in ipairs(entries[1].paths) do
        by_path[path.path] = path
      end

      assert.are.same("D", by_path["/trunk/b.txt"].action)
      assert.are.same("file", by_path["/trunk/b.txt"].kind)
      assert.is_nil(by_path["/trunk/b.txt"].copyfrom_path)

      assert.are.same("A", by_path["/trunk/copy.txt"].action)
      assert.are.same("/trunk/a.txt", by_path["/trunk/copy.txt"].copyfrom_path)
      assert.are.same(3, by_path["/trunk/copy.txt"].copyfrom_rev)

      assert.are.same(
        { "M /trunk/a.txt", "A /trunk/new.txt" },
        vim.tbl_map(function(path)
          return path.action .. " " .. path.path
        end, entries[2].paths)
      )
    end)

    it("shows the history of a path", function()
      assert.are.same({ 5, 3, 2 }, revisions(svn.log.list { path = "a.txt" }))
    end)

    it("follows copies unless told to stop", function()
      wc:update()

      assert.are.same({ 4, 3, 2 }, revisions(svn.log.list { path = "copy.txt" }))
      assert.are.same({ 4 }, revisions(svn.log.list { path = "copy.txt", stop_on_copy = true }))
    end)

    it("searches the messages", function()
      local entries = svn.log.list { search = "*line 19*" }

      assert.are.same(1, #entries)
      assert.are.same(5, entries[1].revision)

      entries = svn.log.list { search = { "*line 19*", "*copy*" } }
      assert.are.same(2, #entries)
    end)

    it("accepts a revision range", function()
      assert.are.same({ 2, 3, 4 }, revisions(svn.log.list { revision = "2:4" }))
    end)

    it("fetches a single revision with its paths", function()
      local entry = svn.log.revision(5)

      assert.are.same(5, entry.revision)
      assert.are.same("Change line 19", entry.subject)
      assert.are.same("/trunk/a.txt", entry.paths[1].path)
    end)

    it("falls back to the history of the base when the path is gone in HEAD", function()
      -- b.txt was deleted in revision 4, but another working copy still has it
      local other = wc:checkout()
      other:svn("update", "-r", "3")
      other:use()

      assert.are.same({ 2 }, revisions(svn.log.list { path = "b.txt" }))
    end)

    it("shows the history of a deleted path through a peg revision", function()
      local entries
      local notifications = util.capture_notifications(function()
        entries = svn.log.list { path = "^/trunk/b.txt", peg = 3 }
      end)

      assert.are.same({ 2 }, revisions(entries))
      assert.are.same({}, notifications)
    end)

    it("returns nil and notifies when svn fails", function()
      local entries
      local notifications = util.capture_notifications(function()
        entries = svn.log.list { path = "does-not-exist.txt" }
      end)

      assert.is_nil(entries)
      assert.are.same(1, #notifications)
    end)

    it("stays quiet when asked to", function()
      local entries
      local notifications = util.capture_notifications(function()
        entries = svn.log.list { path = "does-not-exist.txt", ignore_error = true }
      end)

      assert.is_nil(entries)
      assert.are.same({}, notifications)
    end)
  end)

  describe("cat", function()
    it("returns the pristine content by default", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      local content = svn.cat.file("a.txt")

      assert.is_truthy(content:find("line 2\n", 1, true))
      assert.is_falsy(content:find("line 2 changed", 1, true))
      assert.are.same("\n", content:sub(-1))
    end)

    it("preserves the state of the trailing newline", function()
      assert.are.same("hello\n", svn.cat.file("b.txt"))
      assert.are.same("no newline at the end", svn.cat.file("noeol.txt"))
    end)

    it("returns an empty file as an empty string", function()
      wc:write("empty.txt", "")
      wc:add("empty.txt")
      wc:commit("Add an empty file")

      assert.are.same("", svn.cat.file("empty.txt"))
    end)

    it("preserves blank lines, carriage returns and NUL bytes", function()
      local content = "one\r\n\r\n\r\nfour\0five\n\n"
      wc:write("odd.bin", content)
      wc:add("odd.bin")
      wc:commit("Add odd content")

      assert.are.same(content, svn.cat.file("odd.bin"))
    end)

    it("returns the content of an older revision", function()
      make_history()

      local old = svn.cat.file("a.txt", 2)
      local new = svn.cat.file("a.txt", "HEAD")

      assert.is_truthy(old:find("line 2\n", 1, true))
      assert.is_truthy(new:find("line 2 changed\n", 1, true))
      assert.is_truthy(new:find("line 19 changed\n", 1, true))
    end)

    it("reads files that are gone, through a peg revision", function()
      make_history()
      wc:update()

      assert.are.same("hello\n", svn.cat.file("^/trunk/b.txt", 3, { peg = 3 }))
    end)

    it("returns the content by line", function()
      local lines, eol = svn.cat.lines("b.txt")
      assert.are.same({ "hello" }, lines)
      assert.is_true(eol)

      lines, eol = svn.cat.lines("noeol.txt")
      assert.are.same({ "no newline at the end" }, lines)
      assert.is_false(eol)
    end)

    it("returns nil and the error for unknown files", function()
      local content, err
      util.capture_notifications(function()
        content, err = svn.cat.file("does-not-exist.txt")
      end)

      assert.is_nil(content)
      assert.is_truthy(err:match("svn: "))
    end)

    it("accepts odd file names", function()
      wc:write("a dir/icon@2x.txt", "content\n")
      wc:add("a dir")
      wc:commit("Add an oddly named file")

      assert.are.same("content\n", svn.cat.file("a dir/icon@2x.txt"))
    end)
  end)

  describe("blame", function()
    before_each(make_history)

    it("blames the working file, with uncommitted lines", function()
      wc:replace("a.txt", "line 10\n", "line 10 changed locally\nand a local line\n")

      local lines = svn.blame.file("a.txt")

      -- One entry per line of the file on disk
      assert.are.same(21, #lines)
      assert.are.same(1, lines[1].line)
      assert.are.same(21, lines[21].line)

      assert.are.same(2, lines[1].revision)
      assert.are.same(3, lines[2].revision)
      assert.are.same(vim.env.USER, lines[2].author)
      assert.is_truthy(lines[2].date:match("^%d%d%d%d%-%d%d%-%d%dT"))

      assert.is_nil(lines[10].revision)
      assert.is_nil(lines[10].author)
      assert.is_nil(lines[11].revision)

      -- Shifted down by the local line
      assert.are.same(5, lines[20].revision)
    end)

    it("blames a revision", function()
      local lines = svn.blame.file("a.txt", 3)

      assert.are.same(20, #lines)
      assert.are.same(3, lines[2].revision)
      assert.are.same(2, lines[19].revision)
    end)

    it("blames the base revision, ignoring local changes", function()
      wc:replace("a.txt", "line 10\n", "line 10 changed locally\nand a local line\n")

      local lines = svn.blame.file("a.txt", "BASE")

      assert.are.same(20, #lines)
      assert.are.same(2, lines[10].revision)
      assert.are.same(5, lines[19].revision)
    end)

    it("returns nil and the error when svn fails", function()
      local lines, err
      local notifications = util.capture_notifications(function()
        lines, err = svn.blame.file("does-not-exist.txt")
      end)

      assert.is_nil(lines)
      assert.is_string(err)
      assert.are.same(1, #notifications)
    end)
  end)

  describe("info", function()
    it("describes the working copy root", function()
      local info = svn.info.get()

      assert.are.same(".", info.path)
      assert.are.same("dir", info.kind)
      assert.are.same(wc.url, info.url)
      assert.are.same("^/trunk", info.relative_url)
      assert.are.same(wc.repo_url, info.repos_root)
      assert.is_truthy(info.uuid:match("^%x+%-%x+%-%x+%-%x+%-%x+$"))
      assert.are.same(wc.path, info.wc_root)
      assert.are.same(2, info.revision)
      assert.are.same(2, info.last_changed_rev)
      assert.are.same(vim.env.USER, info.last_changed_author)
      assert.is_truthy(info.last_changed_date:match("^%d%d%d%d%-%d%d%-%d%dT"))
      assert.are.same("normal", info.schedule)
      assert.are.same({}, info.conflicts)
    end)

    it("describes a file", function()
      make_history()

      local info = svn.info.get("a.txt")

      assert.are.same("a.txt", info.path)
      assert.are.same("file", info.kind)
      assert.are.same("^/trunk/a.txt", info.relative_url)
      assert.are.same(5, info.revision)
      assert.are.same(5, info.last_changed_rev)
    end)

    it("reports the changelist and the schedule", function()
      wc:write("added.txt", "added\n")
      wc:add("added.txt")
      wc:changelist("review", "added.txt")

      local info = svn.info.get("added.txt")

      assert.are.same("add", info.schedule)
      assert.are.same("review", info.changelist)
    end)

    it("describes several paths at once and skips unknown ones", function()
      wc:write("new.txt", "new\n")

      local infos = svn.info.list({ "a.txt", "new.txt", "src" }, { ignore_error = true })

      assert.are.same(
        { { "a.txt", "file" }, { "src", "dir" } },
        vim.tbl_map(function(info)
          return { info.path, info.kind }
        end, infos)
      )
    end)

    it("returns nil for a path svn does not know", function()
      wc:write("new.txt", "new\n")

      assert.is_nil(svn.info.get("new.txt", { ignore_error = true }))
    end)

    it("describes a conflict", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:update()

      local info = svn.info.get("a.txt")

      assert.are.same("text", info.conflicts[1].type)
      assert.are.same("update", info.conflicts[1].operation)
      assert.are.same(wc:abs("a.txt.mine"), info.conflicts[1].mine_file)
      assert.are.same(wc:abs("a.txt.r2"), info.conflicts[1].base_file)
      assert.are.same(wc:abs("a.txt.r3"), info.conflicts[1].theirs_file)
    end)
  end)
end)
