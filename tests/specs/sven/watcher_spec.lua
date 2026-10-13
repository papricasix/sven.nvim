local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

describe("watcher", function()
  local Watcher, wc, watcher

  ---Something to register with the watcher, like a status buffer
  ---@param id string
  local function fake_buffer(id)
    local buffer = { redraws = 0 }

    function buffer:id()
      return id
    end

    function buffer:redraw()
      self.redraws = self.redraws + 1
    end

    return buffer
  end

  before_each(function()
    wc = harness.create()
    harness.setup { filewatcher = { enabled = true } }

    Watcher = require("sven.watcher")
    watcher = Watcher.instance(wc.path)
  end)

  after_each(function()
    for id, buffer in pairs(watcher.buffers) do
      watcher:unregister(buffer)
      assert.is_nil(watcher.buffers[id])
    end

    harness.cleanup()
  end)

  it("is one per working copy and watches its administrative directory", function()
    assert.are.equal(watcher, Watcher.instance(wc.path))
    assert.are.same(wc.path, watcher.root)
    assert.are.same(wc:abs(".svn"), watcher.admin_dir)
    assert.is_false(watcher.running)
  end)

  it("defaults to the current working copy", function()
    assert.are.equal(watcher, Watcher.instance())
  end)

  it("runs while a buffer is registered", function()
    local first, second = fake_buffer("first"), fake_buffer("second")

    watcher:register(first)
    assert.is_true(watcher.running)

    watcher:register(second)
    watcher:unregister(first)
    assert.is_true(watcher.running)

    watcher:unregister(second)
    assert.is_false(watcher.running)
  end)

  it("redraws the registered buffers when svn changes the working copy", function()
    local buffer = fake_buffer("spec")
    watcher:register(buffer)

    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:changelist("sven-staged", "a.txt")

    assert.is_true(util.wait_for(function()
      return buffer.redraws > 0
    end, 5000))

    -- The state was refreshed before the redraw
    assert.are.same("a.txt", wc:repo().state.staged.items[1].name)
  end)

  it("does not redraw because of its own refresh", function()
    local buffer = fake_buffer("spec")
    watcher:register(buffer)

    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:changelist("sven-staged", "a.txt")

    assert.is_true(util.wait_for(function()
      return buffer.redraws > 0
    end, 5000))
    harness.settle()

    -- svn status and svn info read the working copy database, they do not write it
    local redraws = buffer.redraws
    vim.wait(1000, function()
      return false
    end)

    assert.are.same(redraws, buffer.redraws)
  end)

  it("ignores changes to working files", function()
    local buffer = fake_buffer("spec")
    watcher:register(buffer)

    wc:replace("a.txt", "line 2\n", "line 2 changed\n")
    wc:write("new.txt", "new\n")

    vim.wait(1000, function()
      return false
    end)

    assert.are.same(0, buffer.redraws)
  end)

  it("can redraw on demand", function()
    local buffer = fake_buffer("spec")
    watcher:register(buffer)

    watcher:dispatch_refresh()

    assert.is_true(util.wait_for(function()
      return buffer.redraws == 1
    end))
  end)

  it("does nothing when it is disabled", function()
    harness.setup { filewatcher = { enabled = false } }

    local buffer = fake_buffer("spec")
    watcher:register(buffer)

    assert.is_false(watcher.running)
  end)
end)
