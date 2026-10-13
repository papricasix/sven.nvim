local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local update = require("sven.lib.svn.update")
local resolve = require("sven.lib.svn.resolve")

---@param items SvenStatusItem[]
---@return string[]
local function names(items)
  return vim.tbl_map(function(item)
    return item.name
  end, items)
end

describe("lib.svn.update", function()
  describe("#parse", function()
    it("parses the actions, the conflicts and the revision", function()
      local summary = update.parse {
        "Updating '.':",
        "CC   a.txt",
        "   C noeol.txt",
        "A    incoming.txt",
        "D    gone.txt",
        "U    src/main.c",
        " U   docs",
        "G    merged with space.txt",
        "Updated to revision 5.",
        "Summary of conflicts:",
        "  Text conflicts: 1",
        "  Property conflicts: 1",
        "  Tree conflicts: 1",
      }

      assert.are.same(5, summary.revision)
      assert.are.same(7, #summary.items)
      -- a.txt and the tree conflict of noeol.txt are the two conflicts, docs counts for its properties
      assert.are.same({ C = 2, A = 1, D = 1, U = 2, G = 1 }, summary.counts)

      assert.are.same({
        { path = "a.txt", text = true, prop = true, tree = false },
        { path = "noeol.txt", text = false, prop = false, tree = true },
      }, summary.conflicts)

      assert.are.same({
        path = "merged with space.txt",
        action = "G",
        prop_action = " ",
        lock_broken = false,
        tree_conflict = false,
      }, summary.items[7])
      assert.are.same("U", summary.items[6].prop_action)
      assert.are.same(" ", summary.items[6].action)
    end)

    it("parses an update that changed nothing", function()
      local summary = update.parse { "Updating '.':", "At revision 7." }

      assert.are.same(7, summary.revision)
      assert.are.same({}, summary.items)
      assert.are.same({}, summary.conflicts)
      assert.are.same({}, summary.counts)
    end)
  end)

  describe("in a working copy", function()
    local wc, other

    before_each(function()
      wc = harness.create()
      other = wc:checkout()
    end)

    after_each(function()
      harness.cleanup()
    end)

    it("brings in changes from the repository", function()
      other:replace("a.txt", "line 5\n", "line 5 changed\n")
      other:write("incoming.txt", "incoming\n")
      other:add("incoming.txt")
      other:delete("b.txt")
      other:commit("Change, add, delete")

      local summary = update.run()

      assert.is_true(summary.ok)
      assert.are.same(3, summary.revision)
      assert.are.same({ U = 1, A = 1, D = 1 }, summary.counts)
      assert.are.same({}, summary.conflicts)

      assert.is_truthy(wc:read("a.txt"):find("line 5 changed", 1, true))
      assert.are.same("incoming\n", wc:read("incoming.txt"))
      assert.is_false(wc:exists("b.txt"))

      local state = wc:refresh()
      assert.are.same(3, state.info.revision)
    end)

    it("reports that the working copy is up to date", function()
      local summary = update.run()

      assert.is_true(summary.ok)
      assert.are.same(2, summary.revision)
      assert.are.same({}, summary.items)
    end)

    it("merges changes to different parts of a file", function()
      other:replace("a.txt", "line 2\n", "line 2 from the other working copy\n")
      other:commit("Change line 2")

      wc:replace("a.txt", "line 19\n", "line 19 from here\n")

      local summary = update.run()

      assert.are.same({ G = 1 }, summary.counts)
      assert.are.same({}, summary.conflicts)

      local content = wc:read("a.txt")
      assert.is_truthy(content:find("line 2 from the other working copy", 1, true))
      assert.is_truthy(content:find("line 19 from here", 1, true))
    end)

    it("updates to a given revision and some paths only", function()
      other:replace("a.txt", "line 5\n", "line 5 changed\n")
      other:replace("b.txt", "hello", "bye")
      other:commit("Revision 3")
      other:replace("a.txt", "line 6\n", "line 6 changed\n")
      other:commit("Revision 4")

      local summary = update.run { revision = 3, paths = { "a.txt" } }

      assert.are.same(3, summary.revision)
      assert.are.same(1, #summary.items)
      assert.are.same("a.txt", summary.items[1].path)
      assert.are.same("U", summary.items[1].action)
      assert.are.same("hello\n", wc:read("b.txt"))
      assert.is_falsy(wc:read("a.txt"):find("line 6 changed", 1, true))
    end)

    describe("with a conflict", function()
      local summary

      before_each(function()
        other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
        other:commit("Change line 5")

        wc:replace("a.txt", "line 5\n", "line 5 from here\n")

        summary = update.run()
      end)

      it("postpones the conflict and reports it", function()
        assert.is_true(summary.ok)
        assert.are.same(3, summary.revision)
        assert.are.same({ C = 1 }, summary.counts)
        assert.are.same({ { path = "a.txt", text = true, prop = false, tree = false } }, summary.conflicts)

        local content = wc:read("a.txt")
        assert.is_truthy(content:find("<<<<<<< .mine", 1, true))
        assert.is_truthy(content:find("line 5 from here", 1, true))
        assert.is_truthy(content:find("line 5 from the other working copy", 1, true))
      end)

      it("lands the file in the conflicts bucket", function()
        local state = wc:refresh()

        assert.are.same({ "a.txt" }, names(state.conflicts.items))
        assert.are.same({}, names(state.changes.items))
        assert.are.same({}, names(state.unversioned.items))
      end)

      it("resolves it with the working file", function()
        -- "Edit out the conflict markers": take the local version
        wc:write("a.txt", wc:read("a.txt.mine"))

        local ok = resolve.accept({ "a.txt" }, "working")

        assert.is_true(ok)

        local state = wc:refresh()
        assert.are.same({}, names(state.conflicts.items))
        assert.are.same({ "a.txt" }, names(state.changes.items))
        assert.are.same({}, names(state.unversioned.items))
        assert.is_false(wc:exists("a.txt.mine"))
      end)

      it("resolves it with the local version", function()
        assert.is_true(resolve.accept({ "a.txt" }, "mine-full"))

        local content = wc:read("a.txt")
        assert.is_truthy(content:find("line 5 from here\n", 1, true))
        assert.is_falsy(content:find("line 5 from the other working copy", 1, true))
        assert.is_falsy(content:find("<<<<<<<", 1, true))
        assert.are.same({ "M       a.txt" }, wc:status())
      end)

      it("resolves it with the incoming version", function()
        assert.is_true(resolve.accept({ "a.txt" }, "theirs-full"))

        local content = wc:read("a.txt")
        assert.is_truthy(content:find("line 5 from the other working copy\n", 1, true))
        assert.is_falsy(content:find("line 5 from here", 1, true))
        assert.are.same({}, wc:status())
      end)

      it("resolves every conflict at once", function()
        assert.is_true(resolve.all("theirs-conflict"))

        assert.are.same({}, wc:status())
        assert.are.same({}, names(wc:refresh().conflicts.items))
      end)

      it("accepts absolute paths", function()
        assert.is_true(resolve.accept({ wc:abs("a.txt") }, "mine-conflict"))

        assert.are.same({ "M       a.txt" }, wc:status())
      end)

      it("rejects unknown ways to resolve", function()
        local ok
        local notifications = util.capture_notifications(function()
          ok = resolve.accept({ "a.txt" }, "launch")
        end)

        assert.is_false(ok)
        assert.are.same(1, #notifications)
        assert.are.same("C", wc:status_of("a.txt"))
      end)
    end)

    it("reports and resolves a tree conflict", function()
      other:delete("b.txt")
      other:commit("Delete b.txt")

      wc:replace("b.txt", "hello", "edited here")

      local summary = update.run()

      assert.are.same({ { path = "b.txt", text = false, prop = false, tree = true } }, summary.conflicts)

      local state = wc:refresh()
      assert.are.same({ "b.txt" }, names(state.conflicts.items))
      assert.is_true(state.conflicts.items[1].tree_conflicted)

      assert.is_true(resolve.accept({ "b.txt" }, "working"))

      state = wc:refresh()
      assert.are.same({}, names(state.conflicts.items))
      assert.are.same({ "b.txt" }, names(state.changes.items))
    end)

    it("reports a failing update", function()
      local summary
      local notifications = util.capture_notifications(function()
        summary = update.run { revision = 999 }
      end)

      assert.is_false(summary.ok)
      assert.are.same(1, #notifications)
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    end)
  end)
end)
