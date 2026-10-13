local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local svn = require("sven.lib.svn")
local Repo = require("sven.lib.svn.repository")
local a = require("sven.lib.async")

describe("lib.svn.repository", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  describe("instances", function()
    it("is one per working copy, whatever directory inside it is asked for", function()
      local repo = Repo.instance(wc.path)

      assert.are.same(wc.path, repo.root)
      assert.are.equal(repo, Repo.instance(wc:abs("src/sub")))
      assert.are.equal(repo, Repo.find(wc:abs("docs")))
    end)

    it("finds the working copy of an unversioned directory inside it", function()
      wc:mkdir("unversioned/deep")

      assert.are.equal(wc:repo(), Repo.find(wc:abs("unversioned/deep")))
    end)

    it("keeps the last requested working copy as the current one", function()
      local other = wc:checkout()

      Repo.instance(other.path)
      assert.are.same(other.path, svn.repo.root)

      -- Looking a repository up does not switch
      assert.are.same(wc.path, Repo.find(wc.path).root)
      assert.are.same(other.path, svn.repo.root)

      Repo.instance(wc.path)
      assert.are.same(wc.path, svn.repo.root)
    end)

    it("has no root outside of a working copy", function()
      local dir = util.create_temp_dir()
      local repo = Repo.find(dir)

      assert.are.same("", repo.root)
      assert.is_false(svn.cli.is_inside_working_copy(dir))

      -- Refreshing is a no-op that still calls back
      local called = false
      repo:refresh {
        callback = function()
          called = true
        end,
      }
      assert.is_true(called)

      vim.fn.delete(dir, "rf")
    end)

    it("notices when a directory becomes a working copy", function()
      local dir = wc.base .. "/later"
      vim.fn.mkdir(dir, "p")
      assert.are.same("", Repo.find(dir).root)

      harness.svn({ "checkout", "-q", wc.url, dir }, wc.base)

      assert.are.same(dir, Repo.instance(dir).root)
    end)
  end)

  describe("#relpath", function()
    it("makes paths relative to the root", function()
      local repo = wc:repo()

      assert.are.same("a.txt", repo:relpath(wc:abs("a.txt")))
      assert.are.same("src/sub/util.c", repo:relpath(wc:abs("src/sub/util.c")))
      assert.are.same(".", repo:relpath(wc.path))
      assert.are.same("not/there/yet.txt", repo:relpath(wc:abs("not/there/yet.txt")))
    end)

    it("returns nil for paths outside of the working copy", function()
      local repo = wc:repo()

      assert.is_nil(repo:relpath(wc.base .. "/elsewhere.txt"))
      assert.is_nil(repo:relpath(wc.path .. "-sibling/a.txt"))
      assert.is_nil(repo:relpath(""))
    end)

    it("resolves symlinks", function()
      local link = wc.base .. "/link"
      vim.uv.fs_symlink(wc.path, link)

      assert.are.same("src/main.c", wc:repo():relpath(link .. "/src/main.c"))
      assert.are.equal(wc:repo(), Repo.find(link))
    end)
  end)

  describe("#refresh", function()
    it("fills the state", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")

      local state = wc:refresh()

      assert.are.same(wc.path, state.root)
      assert.are.same("^/trunk", state.info.relative_url)
      assert.are.same(wc.url, state.info.url)
      assert.are.same(2, state.info.revision)
      assert.are.same("a.txt", state.changes.items[1].name)
      assert.are.same("new.txt", state.unversioned.items[1].name)
      assert.are.equal(state, wc:repo().state)
    end)

    it("replaces the state instead of changing it", function()
      local before = wc:refresh()

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      local after = wc:refresh()

      assert.are_not.equal(before, after)
      assert.are.same({}, before.changes.items)
      assert.are.same(1, #after.changes.items)
    end)

    it("does not block", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:refresh()
      wc:replace("b.txt", "hello", "bye")

      local repo = wc:repo()
      local done = false
      repo:refresh {
        source = "spec",
        callback = function()
          done = true
        end,
      }

      -- svn has not answered yet
      assert.is_false(done)
      assert.are.same(1, #repo.state.changes.items)

      assert.is_true(util.wait_for(function()
        return done
      end))
      assert.are.same(2, #repo.state.changes.items)
    end)

    it("returns a task that can be waited for", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      local task = wc:repo():dispatch_refresh()
      local done = task:wait(10000)

      assert.is_true(done)
      assert.are.same(1, #wc:repo().state.changes.items)
    end)

    it("calls every callback once when refreshes pile up", function()
      local repo = wc:repo()
      local calls = { first = 0, second = 0, third = 0 }

      for _ = 1, 5 do
        repo:refresh {
          source = "first",
          callback = function()
            calls.first = calls.first + 1
          end,
        }
      end

      repo:refresh {
        source = "second",
        callback = function()
          calls.second = calls.second + 1
        end,
      }

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      repo:refresh {
        source = "third",
        callback = function()
          calls.third = calls.third + 1
        end,
      }

      assert.is_true(util.wait_for(function()
        return calls.third > 0
      end))

      -- Let anything that should not happen, happen
      vim.wait(200, function()
        return false
      end)

      assert.are.same({ first = 1, second = 1, third = 1 }, calls)
      -- The callbacks saw the state of the last refresh
      assert.are.same(1, #repo.state.changes.items)
    end)

    it("can be called from an async context", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")

      local count
      a.void(function()
        wc:repo():refresh {
          source = "async",
          callback = function()
            count = #wc:repo().state.changes.items
          end,
        }
      end)()

      assert.is_true(util.wait_for(function()
        return count ~= nil
      end))
      assert.are.same(1, count)
    end)

    it("keeps the previous state when svn fails", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:refresh()

      -- An "svn" that fails whatever it is asked
      harness.setup { svn_executable = "/usr/bin/false" }

      local state
      local notifications = util.capture_notifications(function()
        state = wc:refresh()
      end)

      assert.are.same(1, #state.changes.items)
      assert.are.same("^/trunk", state.info.relative_url)
      assert.is_true(#notifications > 0)
    end)

    it("forgets everything on reset", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:refresh()
      wc:wait_for_recent()

      local repo = wc:repo()
      repo:reset()

      assert.are.same({}, repo.state.changes.items)
      assert.are.same({}, repo.state.recent.items)
      assert.is_nil(repo.state.info)
      assert.are.same(wc.path, repo.state.root)

      assert.are.same(1, #wc:refresh().changes.items)
    end)
  end)

  describe("recent log entries", function()
    it("arrive after the refresh and announce themselves", function()
      local repo = wc:repo()

      local events = {}
      local autocmd = vim.api.nvim_create_autocmd("User", {
        pattern = "SvenRecentLoaded",
        callback = function(event)
          table.insert(events, event.data)
        end,
      })

      wc:refresh()
      local recent = wc:wait_for_recent()

      assert.are.same(2, #recent)
      assert.are.same(2, recent[1].revision)
      assert.are.same(1, recent[2].revision)
      assert.are.same("Add the initial files", recent[1].subject)
      assert.are.equal(recent, repo.state.recent.items)

      assert.is_true(#events >= 1)
      assert.are.same({ root = wc.path }, events[1])

      vim.api.nvim_del_autocmd(autocmd)
    end)

    it("are cached until the working copy moves on", function()
      local function log_calls()
        return #vim.tbl_filter(function(result)
          return result.cmd:match(" log ") ~= nil
        end, svn.cli.history)
      end

      wc:refresh()
      wc:wait_for_recent()
      local calls = log_calls()

      wc:refresh()
      wc:refresh()
      wc:wait_for_recent()
      assert.are.same(calls, log_calls())

      -- A new revision arrives through an update
      local other = wc:checkout()
      other:replace("a.txt", "line 2\n", "line 2 changed\n")
      other:commit("Change line 2")
      wc:update()

      wc:refresh()
      local recent = wc:wait_for_recent()

      assert.is_true(log_calls() > calls)
      assert.are.same(3, recent[1].revision)
    end)

    it("can be refetched on demand", function()
      wc:refresh()
      wc:wait_for_recent()

      -- Committed elsewhere: the base revision of this working copy does not change
      local other = wc:checkout()
      other:replace("a.txt", "line 2\n", "line 2 changed\n")
      other:commit("Change line 2")

      wc:refresh()
      assert.are.same(2, wc:wait_for_recent()[1].revision)

      wc:repo():refresh_recent { force = true }
      assert.are.same(3, wc:wait_for_recent()[1].revision)
    end)

    it("honors the configured count", function()
      harness.setup { status = { recent_commit_count = 1 } }

      wc:refresh()
      assert.are.same(1, #wc:wait_for_recent())
    end)

    it("are not fetched when the count is zero", function()
      harness.setup { status = { recent_commit_count = 0 } }

      wc:refresh()
      assert.are.same({}, wc:wait_for_recent())
    end)
  end)
end)

describe("lib.svn.cli", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  it("runs svn in the working copy root and returns the output", function()
    local result = svn.cli.run { "info", "--show-item", "relative-url" }

    assert.are.same(0, result.code)
    assert.is_true(result:success())
    assert.are.same({ "^/trunk" }, result.stdout)
    assert.are.same({}, result.stderr)
  end)

  it("keeps the exact output when asked for it", function()
    local result = svn.cli.run({ "cat" }, { paths = { "b.txt" }, raw = true })
    assert.are.same({ "hello", "" }, result.stdout)

    result = svn.cli.run({ "cat" }, { paths = { "noeol.txt" }, raw = true })
    assert.are.same({ "no newline at the end" }, result.stdout)
  end)

  it("never asks questions", function()
    local result = svn.cli.run { "info", "--show-item", "url" }

    assert.is_truthy(result.cmd:match(" %-%-non%-interactive "))
  end)

  it("uses untranslated messages without breaking non-ASCII paths", function()
    wc:write("ümlaut.txt", "ü\n")
    wc:add("ümlaut.txt")

    local result = svn.cli.run({ "diff" }, { env = { LANG = "de_DE.UTF-8" } })

    assert.are.same("Index: ümlaut.txt", result.stdout[1])
    assert.are.same("--- ümlaut.txt\t(nonexistent)", result.stdout[3])
    assert.are.same("+++ ümlaut.txt\t(working copy)", result.stdout[4])
  end)

  it("escapes paths that contain an @", function()
    wc:write("icon@2x.txt", "x\n")

    local result = svn.cli.run({ "add" }, { paths = { "icon@2x.txt" } })

    assert.are.same(0, result.code)
    assert.are.same("A", wc:status_of("icon@2x.txt"))
    assert.are.same("icon@2x.txt@", svn.cli.target("icon@2x.txt"))
    assert.are.same("a.txt", svn.cli.target("a.txt"))
    assert.are.same("a.txt@5", svn.cli.target("a.txt", 5))
  end)

  it("accepts paths that start with a dash", function()
    wc:write("-dash.txt", "x\n")

    local result = svn.cli.run({ "add" }, { paths = { "-dash.txt" } })

    assert.are.same(0, result.code)
    assert.are.same("A", wc:status_of("-dash.txt"))
  end)

  it("sends input to stdin", function()
    local result = svn.cli.run(
      { "propset", "note", "-F", "-" },
      { input = "from stdin", paths = { "a.txt" } }
    )

    assert.are.same(0, result.code)
    assert.are.same("from stdin", vim.trim(wc:svn("propget", "note", "a.txt")))
  end)

  it("notifies about failures and returns the result", function()
    local result
    local notifications = util.capture_notifications(function()
      result = svn.cli.run { "cat", "does-not-exist.txt" }
    end)

    assert.is_true(result.code > 0)
    assert.is_true(result:failure())
    assert.is_truthy(table.concat(result.stderr, "\n"):match("E%d+"))

    assert.are.same(1, #notifications)
    assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].message:match("svn: "))
    assert.is_falsy(notifications[1].message:match("non%-interactive"))
  end)

  it("stays quiet about failures when told to", function()
    local result
    local notifications = util.capture_notifications(function()
      result = svn.cli.run({ "cat", "does-not-exist.txt" }, { ignore_error = true })
    end)

    assert.is_true(result.code > 0)
    assert.are.same({}, notifications)
  end)

  it("lets the caller decide about failures", function()
    local seen
    local notifications = util.capture_notifications(function()
      svn.cli.run({ "cat", "does-not-exist.txt" }, {
        on_error = function(res)
          seen = res.code
          return false
        end,
      })
    end)

    assert.is_true(seen > 0)
    assert.are.same({}, notifications)
  end)

  it("records commands in the history, hidden ones marked", function()
    local before = #svn.cli.history

    svn.cli.run { "info", "--show-item", "url" }
    svn.cli.run({ "info", "--show-item", "revision" }, { hidden = true })

    assert.are.same(before + 2, #svn.cli.history)
    assert.is_falsy(svn.cli.history[before + 1].hidden)
    assert.is_true(svn.cli.history[before + 2].hidden)
  end)

  it("shows hidden commands in the history when they fail", function()
    util.capture_notifications(function()
      svn.cli.run({ "cat", "does-not-exist.txt" }, { hidden = true })
    end)

    assert.is_false(svn.cli.history[#svn.cli.history].hidden)
  end)

  it("does not block inside an async context", function()
    local result
    local returned_early = false

    a.void(function()
      result = svn.cli.run { "info", "--show-item", "revision" }
    end)()
    returned_early = result == nil

    assert.is_true(returned_early)
    assert.is_true(util.wait_for(function()
      return result ~= nil
    end))
    assert.are.same({ "2" }, result.stdout)
  end)

  it("blocks inside an async context when told to", function()
    local result

    a.void(function()
      result = svn.cli.run({ "info", "--show-item", "revision" }, { await = true })
    end)()

    assert.are.same({ "2" }, result.stdout)
  end)

  it("reports a missing executable instead of raising", function()
    harness.setup { svn_executable = "/nonexistent/svn" }

    local result
    local notifications = util.capture_notifications(function()
      result = svn.cli.run { "status" }
    end)

    assert.are.same(127, result.code)
    assert.is_true(result:failure())
    assert.are.same(1, #notifications)
    assert.is_truthy(notifications[1].message:match("not found"))
  end)

  it("runs in another directory when asked to", function()
    local result = svn.cli.run({ "info", "--show-item", "relative-url" }, { cwd = wc:abs("src") })

    assert.are.same({ "^/trunk/src" }, result.stdout)
  end)
end)
