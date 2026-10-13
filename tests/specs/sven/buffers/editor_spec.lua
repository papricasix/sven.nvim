local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")
local a = require("sven.lib.async")

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("buffers.editor", function()
  local Editor

  ---The result of the editor: "pending" until it calls back
  local result

  ---@param opts SvenEditorOpts|nil
  ---@return EditorBuffer
  local function open(opts)
    result = "pending"

    local editor = Editor.new(vim.tbl_extend("force", {
      on_done = function(message)
        result = message == nil and "aborted" or message
      end,
    }, opts or {}))
    editor:open("split")
    vim.cmd("stopinsert")

    return editor
  end

  ---@return string|nil result The message or "aborted". nil when the editor never called back
  local function wait_for_result()
    util.wait_for(function()
      return result ~= "pending"
    end, 3000)

    return result ~= "pending" and result or nil
  end

  ---@param lines string[]
  local function type_message(lines)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, lines)
  end

  before_each(function()
    harness.setup()
    Editor = require("sven.buffers.editor")
  end)

  after_each(function()
    util.reset_editor()
  end)

  describe("#extract_message", function()
    local footer = { "#", "# Commands:", "#   q Close", "#" }

    it("drops the generated comment block", function()
      assert.are.same(
        "Subject\n\nBody",
        Editor.extract_message({ "Subject", "", "Body", "", "#", "# Commands:", "#   q Close", "#" }, footer)
      )
    end)

    it("drops blank lines around the message", function()
      assert.are.same("Subject", Editor.extract_message({ "", "  ", "Subject", "", "", "#", "# x" }, {}))
    end)

    it("keeps lines starting with # inside the message", function()
      assert.are.same(
        "#123 fix the frobnicator\n\n# not a comment\nmore text",
        Editor.extract_message(
          { "#123 fix the frobnicator", "", "# not a comment", "more text", "", "#", "# help" },
          {}
        )
      )
    end)

    it("drops the comment block even when something was written below it", function()
      assert.are.same(
        "Subject\n\nwritten below",
        Editor.extract_message(
          { "Subject", "", "#", "# Commands:", "#   q Close", "#", "written below" },
          footer
        )
      )
    end)

    it("returns an empty string when only comments are left", function()
      assert.are.same("", Editor.extract_message({ "", "", "#", "# Commands:", "#   q Close", "#" }, footer))
      assert.are.same("", Editor.extract_message({}, footer))
    end)
  end)

  describe("the buffer", function()
    it("looks like Neogit's commit editor", function()
      local editor = open { comments = { "Changes to be committed:", "  M a.txt" } }

      assert.are.same("gitcommit", vim.bo.filetype)
      assert.are.same("", vim.bo.buftype)
      assert.is_true(vim.bo.modifiable)
      assert.is_false(vim.bo.modified)
      assert.are.same(editor.filename, vim.api.nvim_buf_get_name(0))
      assert.are.same("SVEN_COMMIT_EDITMSG", vim.fs.basename(editor.filename))
      assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))

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
        "#",
      }, vim.api.nvim_buf_get_lines(0, 0, -1, false))

      feed("<c-c><c-k>")
      wait_for_result()
    end)

    it("starts with the given message", function()
      open { message = "Try again\n\nWith a body" }

      assert.are.same({ "Try again", "", "With a body", "", "#" }, vim.api.nvim_buf_get_lines(0, 0, 5, false))

      feed("<c-c><c-k>")
      wait_for_result()
    end)

    it("leaves out the help for unbound mappings", function()
      harness.setup { mappings = { commit_editor = { ["<m-p>"] = false, ["<m-n>"] = false } } }
      open()

      local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_falsy(lines:match("Previous Message"))
      assert.is_falsy(lines:match("Next Message"))
      assert.is_truthy(lines:match("Reset Message"))

      feed("<c-c><c-k>")
      wait_for_result()
    end)
  end)

  describe("submitting", function()
    it("hands over the message with <c-c><c-c>", function()
      open()
      type_message { "A subject", "", "A body line" }

      feed("<c-c><c-c>")

      assert.are.same("A subject\n\nA body line", wait_for_result())
      assert.are_not.same("gitcommit", vim.bo.filetype)
    end)

    it("works from insert mode", function()
      open()

      feed("iTyped in insert mode<c-c><c-c>")

      assert.are.same("Typed in insert mode", wait_for_result())
    end)

    it("hands over the message with ZZ", function()
      open()
      type_message { "With ZZ" }

      feed("ZZ")

      assert.are.same("With ZZ", wait_for_result())
    end)

    it("hands over the message with :wq", function()
      open()
      type_message { "With wq" }

      vim.cmd("wq")

      assert.are.same("With wq", wait_for_result())
    end)

    it("hands over what was saved when closed with q", function()
      open()
      type_message { "Saved, then closed" }
      vim.cmd("write")

      feed("q")

      assert.are.same("Saved, then closed", wait_for_result())
    end)

    it("removes its temporary file", function()
      local editor = open()
      type_message { "A subject" }
      assert.is_not_nil(vim.uv.fs_stat(editor.filename))

      feed("<c-c><c-c>")
      wait_for_result()

      assert.is_nil(vim.uv.fs_stat(editor.filename))
      assert.is_nil(vim.uv.fs_stat(vim.fs.dirname(editor.filename)))
    end)

    it("calls back exactly once", function()
      local calls = 0
      Editor.new({
        on_done = function()
          calls = calls + 1
        end,
      }):open("split")
      vim.cmd("stopinsert")
      type_message { "A subject" }

      feed("<c-c><c-c>")
      util.wait_for(function()
        return calls > 0
      end)
      vim.wait(100, function()
        return false
      end)

      assert.are.same(1, calls)
    end)

    it("announces that it closed", function()
      local closed = false
      local autocmd = vim.api.nvim_create_autocmd("User", {
        pattern = "SvenEditorClosed",
        callback = function()
          closed = true
        end,
      })

      open()
      type_message { "A subject" }
      feed("<c-c><c-c>")
      wait_for_result()

      assert.is_true(closed)
      vim.api.nvim_del_autocmd(autocmd)
    end)
  end)

  describe("aborting", function()
    it("hands over nil with <c-c><c-k>", function()
      open()
      type_message { "Never mind" }

      feed("<c-c><c-k>")

      assert.are.same("aborted", wait_for_result())
    end)

    it("hands over nil with ZQ", function()
      open()
      type_message { "Never mind" }

      feed("ZQ")

      assert.are.same("aborted", wait_for_result())
    end)

    it("hands over nil when closed without writing", function()
      open()
      type_message { "Never mind" }

      vim.cmd("quit!")

      assert.are.same("aborted", wait_for_result())
    end)

    it("hands over nil when closed untouched with q", function()
      open { message = "A message that was offered" }

      feed("q")

      assert.are.same("aborted", wait_for_result())
    end)

    it("treats an empty message as an abort", function()
      local notifications = util.capture_notifications(function()
        open()
        feed("<c-c><c-c>")
        wait_for_result()
      end)

      assert.are.same("aborted", result)
      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("empty commit message"))
    end)

    it("submits an empty message when that is allowed", function()
      open { allow_empty = true }

      feed("<c-c><c-c>")

      assert.are.same("", wait_for_result())
    end)
  end)

  describe("#edit", function()
    it("returns the message inside an async context", function()
      local message = "pending"

      a.void(function()
        message = Editor.edit { kind = "split" }
      end)()

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "gitcommit"
      end))
      vim.cmd("stopinsert")
      type_message { "From an action" }
      feed("<c-c><c-c>")

      assert.is_true(util.wait_for(function()
        return message ~= "pending"
      end))
      assert.are.same("From an action", message)
    end)

    it("returns nil when aborted", function()
      local message = "pending"

      a.void(function()
        message = Editor.edit { kind = "split" }
      end)()

      assert.is_true(util.wait_for(function()
        return vim.bo.filetype == "gitcommit"
      end))
      vim.cmd("stopinsert")
      feed("<c-c><c-k>")

      assert.is_true(util.wait_for(function()
        return message ~= "pending"
      end))
      assert.is_nil(message)
    end)
  end)

  describe("the diff view", function()
    it("is opened next to the editor and closed with it", function()
      local opened, closed = 0, 0

      open {
        diff_view = function()
          opened = opened + 1
          return {
            close = function()
              closed = closed + 1
            end,
          }
        end,
      }

      assert.are.same(1, opened)
      assert.are.same(0, closed)

      feed("<c-c><c-k>")
      wait_for_result()

      assert.are.same(1, closed)
    end)
  end)

  describe("earlier messages", function()
    local wc

    before_each(function()
      wc = harness.create()
      wc:replace("a.txt", "line 2\n", "line 2 changed\n")
      wc:commit("Change line 2\n\nBecause it had to be done.")
      wc:refresh()
      wc:wait_for_recent()
    end)

    after_each(function()
      util.reset_editor()
      harness.cleanup()
    end)

    it("are offered with the PrevMessage and NextMessage mappings", function()
      open()
      type_message { "My draft" }

      feed("<m-p>")
      assert.are.same(
        { "Change line 2", "", "Because it had to be done.", "", "#" },
        vim.api.nvim_buf_get_lines(0, 0, 5, false)
      )

      feed("<m-p>")
      assert.are.same({ "Add the initial files", "", "#" }, vim.api.nvim_buf_get_lines(0, 0, 3, false))

      feed("<m-n>")
      assert.are.same("Change line 2", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])

      feed("<m-n>")
      assert.are.same({ "My draft", "", "#" }, vim.api.nvim_buf_get_lines(0, 0, 3, false))

      feed("<c-c><c-k>")
      wait_for_result()
    end)

    it("can be submitted", function()
      open()

      feed("<m-p>")
      feed("<c-c><c-c>")

      assert.are.same("Change line 2\n\nBecause it had to be done.", wait_for_result())
    end)
  end)
end)
