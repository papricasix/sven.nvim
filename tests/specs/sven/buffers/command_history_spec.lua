local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

---@return string[] The lines of the current buffer, without trailing whitespace
local function buffer_lines()
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("buffers.command_history", function()
  local History, svn, wc

  before_each(function()
    wc = harness.create()
    History = require("sven.buffers.command_history")
    svn = require("sven.lib.svn")
  end)

  after_each(function()
    if History.instance then
      History.instance:close()
    end

    util.reset_editor()
    harness.cleanup()
  end)

  it("lists the commands that were run, without the arguments sven adds", function()
    svn.cli.run { "info", "--show-item", "revision" }

    History:new({ svn.cli.history[#svn.cli.history] }):show()

    assert.are.same("SvenCommandHistory", vim.bo.filetype)
    assert.is_true(History.is_open())

    local lines = buffer_lines()
    assert.is_truthy(lines[1]:match("^  0 .*svn info %-%-show%-item revision"))
    assert.is_truthy(lines[1]:match("%(%s*%d+%.%d+ ms%)"))
    assert.is_truthy(lines[1]:match("%[stdout%s+1%]$"))
    assert.is_falsy(lines[1]:match("non%-interactive"))

    -- The output is below the command, folded away
    assert.are.same("  | 2", lines[2])
    assert.are.same(1, vim.fn.foldclosed(1))
  end)

  it("shows the error output of a failed command", function()
    util.capture_notifications(function()
      svn.cli.run { "cat", "does-not-exist.txt" }
    end)

    History:new({ svn.cli.history[#svn.cli.history] }):show()

    local lines = buffer_lines()
    assert.is_truthy(lines[1]:match("^  1 .*svn cat does%-not%-exist%.txt"))
    assert.is_truthy(lines[1]:match("%[stderr%s+%d+%]$"))
    assert.is_truthy(table.concat(lines, "\n"):match("  | svn: "))
  end)

  it("lists everything sven ran by default, except what it ran on its own", function()
    wc:refresh()
    svn.cli.run { "info", "--show-item", "revision" }

    History:new():show()

    local lines = table.concat(buffer_lines(), "\n")
    assert.is_truthy(lines:match("svn info %-%-show%-item revision"))
    assert.is_falsy(lines:match("status %-%-xml"))
  end)

  it("shows a hidden command once it failed", function()
    util.capture_notifications(function()
      svn.cli.run({ "cat", "does-not-exist.txt" }, { hidden = true })
    end)

    History:new():show()

    assert.is_truthy(table.concat(buffer_lines(), "\n"):match("svn cat does%-not%-exist%.txt"))
  end)

  it("unfolds the output with <tab> and closes with q", function()
    svn.cli.run { "info", "--show-item", "revision" }
    History:new({ svn.cli.history[#svn.cli.history] }):show()

    feed("<tab>")
    assert.are.same(-1, vim.fn.foldclosed(1))

    feed("q")
    assert.is_true(util.wait_for(function()
      return not History.is_open()
    end))
  end)
end)
