local harness = require("tests.util.svn_harness")
local status = require("sven.lib.svn.status")
local svn = require("sven.lib.svn")

---@param items SvenStatusItem[]
---@return string[]
local function names(items)
  return vim.tbl_map(function(item)
    return item.name
  end, items)
end

---@param items SvenStatusItem[]
---@param name string
---@return SvenStatusItem
local function find(items, name)
  for _, item in ipairs(items) do
    if item.name == name then
      return item
    end
  end

  error("No item named " .. name .. " in " .. vim.inspect(names(items)))
end

describe("lib.svn.status", function()
  describe("#parse", function()
    local output = [[
<?xml version="1.0" encoding="UTF-8"?>
<status>
<target
   path=".">
<entry
   path="b.txt">
<wc-status
   item="deleted"
   revision="2"
   props="none">
<commit
   revision="2">
<author>alice</author>
<date>2026-10-12T20:31:44.107693Z</date>
</commit>
</wc-status>
</entry>
<entry
   path="new &amp; shiny.txt">
<wc-status
   item="unversioned"
   props="none">
</wc-status>
</entry>
<entry
   path="src/sub/util.c">
<wc-status
   item="normal"
   revision="2"
   props="modified">
</wc-status>
</entry>
<entry
   path="copy.txt">
<wc-status
   props="none"
   copied="true"
   tree-conflicted="true"
   item="added">
</wc-status>
</entry>
<entry
   path="a.txt">
<wc-status
   props="conflicted"
   item="conflicted"
   revision="5">
</wc-status>
</entry>
<entry
   path="locked">
<wc-status
   props="none"
   wc-locked="true"
   switched="true"
   item="normal"
   revision="5">
</wc-status>
</entry>
</target>
<changelist
   name="sven-staged">
<entry
   path="added.txt">
<wc-status
   props="none"
   item="added"
   revision="-1">
</wc-status>
</entry>
</changelist>
</status>]]

    local items

    before_each(function()
      items = status.parse(output, "/wc")
    end)

    it("returns the items in the order svn printed them", function()
      assert.are.same(
        { "b.txt", "new & shiny.txt", "src/sub/util.c", "copy.txt", "a.txt", "locked", "added.txt" },
        names(items)
      )
    end)

    it("parses a deleted file", function()
      local item = find(items, "b.txt")

      assert.are.same("deleted", item.status)
      assert.are.same("D", item.mode)
      assert.are.same("deleted", item.text_status)
      assert.are.same("none", item.props)
      assert.are.same(" ", item.prop_mode)
      assert.are.same("/wc/b.txt", item.absolute_path)
      assert.are.same("b.txt", item.escaped_path)
      assert.are.same(2, item.revision)
      assert.are.same({ revision = 2, author = "alice", date = "2026-10-12T20:31:44.107693Z" }, item.commit)
      assert.is_nil(item.changelist)
      assert.is_false(item.conflicted)
      assert.is_false(item.copied)
    end)

    it("parses an unversioned file", function()
      local item = find(items, "new & shiny.txt")

      assert.are.same("unversioned", item.status)
      assert.are.same("?", item.mode)
      assert.is_nil(item.revision)
      assert.is_nil(item.commit)
    end)

    it("reports a property-only modification as modified", function()
      local item = find(items, "src/sub/util.c")

      assert.are.same("modified", item.status)
      assert.are.same("M", item.mode)
      assert.are.same("normal", item.text_status)
      assert.are.same("modified", item.props)
      assert.are.same("M", item.prop_mode)
    end)

    it("parses a copied file with a tree conflict", function()
      local item = find(items, "copy.txt")

      assert.are.same("added", item.status)
      assert.is_true(item.copied)
      assert.is_true(item.tree_conflicted)
      assert.is_true(item.conflicted)
      assert.is_false(item.text_conflicted)
    end)

    it("parses text and property conflicts", function()
      local item = find(items, "a.txt")

      assert.are.same("conflicted", item.status)
      assert.are.same("C", item.mode)
      assert.are.same("C", item.prop_mode)
      assert.is_true(item.conflicted)
      assert.is_true(item.text_conflicted)
      assert.is_true(item.prop_conflicted)
      assert.is_false(item.tree_conflicted)
    end)

    it("parses the lock and switch flags", function()
      local item = find(items, "locked")

      assert.is_true(item.locked)
      assert.is_true(item.switched)
      assert.are.same("normal", item.status)
      assert.are.same(" ", item.mode)
    end)

    it("parses changelist membership", function()
      local item = find(items, "added.txt")

      assert.are.same("sven-staged", item.changelist)
      assert.are.same("added", item.status)
      assert.are.same("A", item.mode)
      assert.is_nil(item.revision)
    end)

    it("returns nothing for output that is not a status report", function()
      assert.are.same({}, status.parse("", "/wc"))
      assert.are.same({}, status.parse("svn: E155007: not a working copy", "/wc"))
    end)
  end)

  describe("#is_conflict_artifact", function()
    local conflicted = { ["a.txt"] = true, ["src/main.c"] = true, ["docs"] = true }

    it("recognizes the files svn puts next to a conflicted file", function()
      for _, name in ipairs {
        "a.txt.mine",
        "a.txt.r3",
        "a.txt.r123",
        "a.txt.working",
        "a.txt.merge-left.r1",
        "a.txt.merge-right.r20",
        "a.txt.prej",
        "src/main.c.mine",
        "docs/dir_conflicts.prej",
      } do
        assert.is_true(status.is_conflict_artifact(name, conflicted), name)
      end
    end)

    it("does not hide files that merely look like artifacts", function()
      for _, name in ipairs {
        "b.txt.mine",
        "b.txt.r3",
        "a.txt.rx",
        "a.txt.mine.bak",
        "notes.working",
        "other/dir_conflicts.prej",
        "a.txt",
      } do
        assert.is_false(status.is_conflict_artifact(name, conflicted), name)
      end
    end)
  end)

  describe("#bucket", function()
    local function item(name, item_status, extra)
      return vim.tbl_extend("force", {
        name = name,
        status = item_status,
        text_status = item_status,
        kind = "file",
        conflicted = false,
      }, extra or {})
    end

    it("sorts items into sections", function()
      local buckets = status.bucket({
        item("a.txt", "conflicted", { conflicted = true, changelist = "sven-staged" }),
        item("a.txt.mine", "unversioned"),
        item("a.txt.r3", "unversioned"),
        item("b.txt", "modified"),
        item("c.txt", "modified", { changelist = "sven-staged" }),
        item("d.txt", "added", { changelist = "zeta" }),
        item("e.txt", "deleted", { changelist = "alpha" }),
        item("f.txt", "unversioned"),
        item("g.txt", "missing"),
        item("ext", "external", { kind = "dir" }),
        item("unchanged.txt", "normal", { changelist = "sven-staged" }),
      }, { staging = "sven-staged" })

      assert.are.same({ "a.txt" }, names(buckets.conflicts.items))
      assert.are.same({ "f.txt" }, names(buckets.unversioned.items))
      assert.are.same({ "b.txt", "g.txt" }, names(buckets.changes.items))
      assert.are.same({ "c.txt" }, names(buckets.staged.items))

      assert.are.same(2, #buckets.changelists)
      assert.are.same("alpha", buckets.changelists[1].name)
      assert.are.same({ "e.txt" }, names(buckets.changelists[1].items))
      assert.are.same("zeta", buckets.changelists[2].name)
      assert.are.same({ "d.txt" }, names(buckets.changelists[2].items))
    end)

    it("records the section on every item", function()
      local items = {
        item("a.txt", "conflicted", { conflicted = true }),
        item("b.txt", "modified"),
        item("c.txt", "modified", { changelist = "sven-staged" }),
        item("d.txt", "added", { changelist = "other" }),
        item("f.txt", "unversioned"),
      }
      status.bucket(items, { staging = "sven-staged" })

      assert.are.same(
        { "conflicts", "changes", "staged", "changelist:other", "unversioned" },
        vim.tbl_map(function(i)
          return i.section
        end, items)
      )
    end)

    it("uses the configured staging changelist", function()
      local buckets = status.bucket({
        item("a.txt", "modified", { changelist = "mine" }),
        item("b.txt", "modified", { changelist = "sven-staged" }),
      }, { staging = "mine" })

      assert.are.same({ "a.txt" }, names(buckets.staged.items))
      assert.are.same("sven-staged", buckets.changelists[1].name)
    end)

    it("stages added directories that staged files depend on", function()
      local buckets = status.bucket({
        item("lonely", "added", { kind = "dir" }),
        item("new", "added", { kind = "dir" }),
        item("new/deep", "added", { kind = "dir" }),
        item("new/deep/y.txt", "added", { changelist = "sven-staged" }),
        item("new/other", "added", { kind = "dir" }),
        item("new/other/z.txt", "added"),
        item("new/x.txt", "added"),
      }, { staging = "sven-staged" })

      assert.are.same({ "new", "new/deep", "new/deep/y.txt" }, names(buckets.staged.items))
      assert.are.same({ "lonely", "new/other", "new/other/z.txt", "new/x.txt" }, names(buckets.changes.items))

      assert.is_true(find(buckets.staged.items, "new").implied)
      assert.is_true(find(buckets.staged.items, "new/deep").implied)
      assert.is_nil(find(buckets.staged.items, "new/deep/y.txt").implied)
      assert.are.same("staged", find(buckets.staged.items, "new").section)
    end)

    it("stages a deleted directory only when all of it is staged", function()
      local items = function()
        return {
          item("gone", "deleted", { kind = "dir" }),
          item("gone/a.txt", "deleted", { changelist = "sven-staged" }),
        }
      end

      local partial = status.bucket(items(), {
        staging = "sven-staged",
        is_fully_staged = function()
          return false
        end,
      })
      assert.are.same({ "gone/a.txt" }, names(partial.staged.items))
      assert.are.same({ "gone" }, names(partial.changes.items))

      local full = status.bucket(items(), {
        staging = "sven-staged",
        is_fully_staged = function(dir)
          return dir.name == "gone"
        end,
      })
      assert.are.same({ "gone", "gone/a.txt" }, names(full.staged.items))
      assert.are.same({}, names(full.changes.items))
    end)

    it("leaves a directory with only a property change where it is", function()
      local buckets = status.bucket({
        item("dir", "modified", { kind = "dir", text_status = "normal", props = "modified" }),
        item("dir/a.txt", "modified", { changelist = "sven-staged" }),
      }, { staging = "sven-staged" })

      assert.are.same({ "dir" }, names(buckets.changes.items))
      assert.are.same({ "dir/a.txt" }, names(buckets.staged.items))
    end)
  end)

  describe("in a working copy", function()
    local wc

    before_each(function()
      wc = harness.create()
    end)

    after_each(function()
      harness.cleanup()
    end)

    it("reports a clean working copy as empty", function()
      local state = wc:refresh()

      assert.are.same({}, state.conflicts.items)
      assert.are.same({}, state.unversioned.items)
      assert.are.same({}, state.changes.items)
      assert.are.same({}, state.staged.items)
      assert.are.same({}, state.changelists)
      assert.is_false(status.is_dirty())
    end)

    it("sorts local changes into buckets", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")
      wc:delete("b.txt")
      wc:remove("src/main.c")
      wc:propset("svn:eol-style", "native", "src/sub/util.c")
      wc:write("added.txt", "added\n")
      wc:add("added.txt")
      wc:changelist("sven-staged", "a.txt")
      wc:changelist("other", "added.txt")

      local state = wc:refresh()

      assert.are.same({}, names(state.conflicts.items))
      assert.are.same({ "new.txt", "newdir" }, names(state.unversioned.items))
      assert.are.same({ "b.txt", "src/main.c", "src/sub/util.c" }, names(state.changes.items))
      assert.are.same({ "a.txt" }, names(state.staged.items))
      assert.are.same(1, #state.changelists)
      assert.are.same("other", state.changelists[1].name)
      assert.are.same({ "added.txt" }, names(state.changelists[1].items))

      assert.is_true(status.is_dirty())
      assert.is_true(status.anything_staged())
      assert.is_true(status.anything_unstaged())
      assert.is_false(status.any_conflicts())
    end)

    it("describes the items", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("newdir/x.txt", "x\n")
      wc:delete("b.txt")
      wc:remove("src/main.c")
      wc:propset("svn:eol-style", "native", "src/sub/util.c")
      wc:changelist("sven-staged", "a.txt")

      local state = wc:refresh()

      local a = find(state.staged.items, "a.txt")
      assert.are.same("modified", a.status)
      assert.are.same("M", a.mode)
      assert.are.same("file", a.kind)
      assert.are.same("sven-staged", a.changelist)
      assert.are.same(wc:abs("a.txt"), a.absolute_path)
      assert.are.same(2, a.revision)
      assert.are.same("staged", a.section)

      local dir = find(state.unversioned.items, "newdir")
      assert.are.same("unversioned", dir.status)
      assert.are.same("?", dir.mode)
      assert.are.same("dir", dir.kind)

      -- Neither is on disk anymore, so svn has to tell what they were
      local deleted = find(state.changes.items, "b.txt")
      assert.are.same("deleted", deleted.status)
      assert.are.same("D", deleted.mode)
      assert.are.same("file", deleted.kind)

      local missing = find(state.changes.items, "src/main.c")
      assert.are.same("missing", missing.status)
      assert.are.same("!", missing.mode)
      assert.are.same("file", missing.kind)

      local props = find(state.changes.items, "src/sub/util.c")
      assert.are.same("modified", props.status)
      assert.are.same("normal", props.text_status)
      assert.are.same("modified", props.props)
    end)

    it("knows that a deleted directory is a directory", function()
      wc:delete("src")

      local state = wc:refresh()

      assert.are.same({ "src" }, names(state.changes.items))
      assert.are.same("dir", state.changes.items[1].kind)
      assert.are.same("deleted", state.changes.items[1].status)
    end)

    it("reports an unversioned directory as a single item", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")

      local state = wc:refresh()

      assert.are.same({ "newdir" }, names(state.unversioned.items))
    end)

    it("handles file names with spaces, non-ASCII characters and an @", function()
      wc:write("with space.txt", "x\n")
      wc:write("ümlaut.txt", "x\n")
      wc:write("icon@2x.txt", "x\n")

      local state = wc:refresh()

      assert.are.same({ "icon@2x.txt", "with space.txt", "ümlaut.txt" }, names(state.unversioned.items))
    end)

    it("lists the directories staged files depend on as staged", function()
      wc:write("newdir/x.txt", "x\n")
      wc:write("newdir/deep/y.txt", "y\n")
      wc:add("newdir")
      wc:changelist("sven-staged", "newdir/deep/y.txt")

      local state = wc:refresh()

      assert.are.same({ "newdir", "newdir/deep", "newdir/deep/y.txt" }, names(state.staged.items))
      assert.are.same({ "newdir/x.txt" }, names(state.changes.items))
      assert.is_true(find(state.staged.items, "newdir").implied)
    end)

    it("lists a deleted directory as staged once everything in it is staged", function()
      wc:delete("src")
      wc:changelist("sven-staged", "src/main.c")

      local state = wc:refresh()
      assert.are.same({ "src/main.c" }, names(state.staged.items))
      assert.are.same({ "src" }, names(state.changes.items))

      wc:changelist("sven-staged", "src/sub/util.c")

      state = wc:refresh()
      assert.are.same({ "src", "src/main.c", "src/sub/util.c" }, names(state.staged.items))
      assert.are.same({}, names(state.changes.items))
    end)

    it("puts conflicted files into conflicts and hides their artifacts", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:write("unrelated.txt", "x\n")
      wc:write("a.txt.r99", "not an artifact of this conflict, but it looks like one\n")
      wc:changelist("sven-staged", "a.txt")
      wc:update()

      assert.is_true(wc:exists("a.txt.mine"))

      local state = wc:refresh()

      assert.are.same({ "a.txt" }, names(state.conflicts.items))
      assert.are.same({ "unrelated.txt" }, names(state.unversioned.items))
      assert.are.same({}, names(state.staged.items))

      local conflict = state.conflicts.items[1]
      assert.are.same("conflicted", conflict.status)
      assert.are.same("C", conflict.mode)
      assert.is_true(conflict.text_conflicted)
      assert.are.same("sven-staged", conflict.changelist)
      assert.are.same("conflicts", conflict.section)
      assert.is_true(status.any_conflicts())
    end)

    it("shows the artifacts again once the conflict is resolved", function()
      local other = wc:checkout()
      other:replace("a.txt", "line 5\n", "line 5 from the other working copy\n")
      other:commit("Change line 5")

      wc:replace("a.txt", "line 5\n", "line 5 from here\n")
      wc:write("a.txt.r99", "left over\n")
      wc:update()
      wc:svn("resolve", "--accept", "working", "a.txt")

      local state = wc:refresh()

      assert.are.same({}, names(state.conflicts.items))
      assert.are.same({ "a.txt.r99" }, names(state.unversioned.items))
    end)

    it("finds items by name", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:write("new.txt", "new\n")
      wc:refresh()

      assert.are.same("modified", status.find("a.txt").status)
      assert.are.same("unversioned", status.find("new.txt").status)
      assert.is_nil(status.find("b.txt"))
    end)

    it("fetches the status of some paths only", function()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("src/main.c", "return 0", "return 1")
      wc:write("src/new.c", "x\n")

      local items = status.fetch { paths = { "src" } }

      assert.are.same({ "src/main.c", "src/new.c" }, names(items))
      assert.are.same("file", items[1].kind)
    end)

    it("accepts absolute paths", function()
      wc:replace("src/main.c", "return 0", "return 1")

      local items = status.fetch { paths = { wc:abs("src/main.c") } }

      assert.are.same({ "src/main.c" }, names(items))
      assert.are.same(wc:abs("src/main.c"), items[1].absolute_path)
    end)

    it("uses the staging changelist from the config", function()
      harness.setup { staging_changelist = "ready" }

      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:replace("b.txt", "hello", "bye")
      wc:changelist("ready", "a.txt")
      wc:changelist("sven-staged", "b.txt")

      local state = wc:refresh()

      assert.are.same({ "a.txt" }, names(state.staged.items))
      assert.are.same("sven-staged", state.changelists[1].name)
      assert.are.same("ready", svn.changelist.staging())
    end)
  end)
end)
