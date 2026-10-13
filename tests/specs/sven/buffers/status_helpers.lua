---Helpers shared by the specs that drive the status buffer and the popups opened from it.
---Not a spec itself: the test runner only picks up `*_spec.lua`.
local harness = require("tests.util.svn_harness")
local util = require("tests.util.util")

local M = {}

---@param buf integer|nil Defaults to the current buffer
---@return string[] The lines of a buffer, without trailing whitespace
function M.lines(buf)
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false))
end

---Types keys, mappings included, and waits until they have been processed
---@param keys string
function M.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@param text string A complete line (without trailing whitespace)
---@return integer|nil line The number of the first line that reads `text`
function M.find(text)
  for i, line in ipairs(M.lines()) do
    if line == text then
      return i
    end
  end
end

---@param text string
---@return boolean Whether the current buffer has a line that reads `text`
function M.has(text)
  return M.find(text) ~= nil
end

---Puts the cursor on the first line that reads `text`
---@param text string
---@return integer line
function M.go(text)
  local line = M.find(text)
  assert(line, ("No line reads %q in:\n%s"):format(text, table.concat(M.lines(), "\n")))

  vim.api.nvim_win_set_cursor(0, { line, 0 })
  return line
end

---Blocks until `condition` holds, and fails with the content of the buffer when it never does
---@param condition fun(): boolean|nil
---@param what string|nil What was waited for, for the failure message
---@param timeout integer|nil Milliseconds, defaults to 5000
function M.wait(condition, what, timeout)
  local ok = util.wait_for(function()
    return condition() and true or false
  end, timeout or 5000)

  assert(
    ok,
    ("Timed out waiting for %s. The buffer (%s) reads:\n%s"):format(
      what or "a condition",
      vim.bo.filetype,
      table.concat(M.lines(), "\n")
    )
  )
end

---Blocks until the current buffer has a line that reads `text`
---@param text string
---@param timeout integer|nil
function M.wait_for_line(text, timeout)
  M.wait(function()
    return M.has(text)
  end, ("the line %q"):format(text), timeout)
end

---Blocks until no line of the current buffer reads `text`
---@param text string
---@param timeout integer|nil
function M.wait_for_no_line(text, timeout)
  M.wait(function()
    return not M.has(text)
  end, ("the line %q to go away"):format(text), timeout)
end

---Lets everything that is scheduled or running in the background finish
function M.settle()
  for _ = 1, 3 do
    harness.settle()
    vim.wait(30, function()
      return false
    end)
  end
end

---Opens the status buffer of a working copy and waits until it shows its state
---@param wc SvnHarnessWorkingCopy
---@param opts { kind: string?, recent: boolean? }|nil `recent` also waits for the log entries
---@return StatusBuffer
function M.open(wc, opts)
  opts = opts or {}

  require("sven").open { cwd = wc.path, kind = opts.kind or "split" }

  M.wait(function()
    if vim.bo.filetype ~= "SvenStatus" then
      return false
    end

    for _, line in ipairs(M.lines()) do
      if line:match("^Head:%s+r%d+") then
        return true
      end
    end
  end, "the status buffer to show the working copy")
  M.settle()

  if opts.recent then
    wc:wait_for_recent()
    M.wait(function()
      return M.has("Recent commits")
    end, "the recent commits")
  end

  return assert(require("sven.buffers.status").instance(wc.path))
end

---Closes the status buffer and resets the editor. For `after_each`, before `harness.cleanup()`.
function M.close()
  M.settle()

  local popup = require("sven.lib.popup")
  if popup.is_open() then
    popup.instance:close()
  end

  util.reset_editor()
end

---Answers the confirmations sven asks for, and records them.
---@param answer boolean|fun(message: string): boolean
---@return string[] questions The messages that were asked, in order
---@return fun() restore Puts the real prompt back
function M.answer_permissions(answer)
  local input = require("sven.lib.input")
  local original = input.get_permission
  local questions = {}

  input.get_permission = function(message)
    table.insert(questions, message)

    if type(answer) == "function" then
      return answer(message)
    end

    return answer
  end

  return questions, function()
    input.get_permission = original
  end
end

---Answers the prompts sven asks for with a line of text, and records them.
---@param answer string|nil nil cancels the prompt
---@return string[] prompts The prompts that were shown, in order
---@return fun() restore Puts the real prompt back
function M.answer_input(answer)
  local input = require("sven.lib.input")
  local original = input.get_user_input
  local prompts = {}

  input.get_user_input = function(prompt)
    table.insert(prompts, prompt)
    return answer
  end

  return prompts, function()
    input.get_user_input = original
  end
end

---Keeps the notifications of sven out of the output of the test run. Specs that assert on them
---still can, with `util.capture_notifications`.
---@return fun() restore Puts the real `vim.notify` back
function M.silence_notifications()
  local original = vim.notify
  vim.notify = function() end

  return function()
    vim.notify = original
  end
end

---Makes `require(name)` return `module`, until `M.unstub_modules()` is called.
---@param name string
---@param module table|fun(): table A function is run on require, and may raise
function M.stub_module(name, module)
  M.stubbed = M.stubbed or {}
  table.insert(M.stubbed, name)

  package.loaded[name] = nil
  package.preload[name] = type(module) == "function" and module or function()
    return module
  end
end

---Forgets the modules stubbed with `M.stub_module`
function M.unstub_modules()
  for _, name in ipairs(M.stubbed or {}) do
    package.preload[name] = nil
    package.loaded[name] = nil
  end

  M.stubbed = {}
end

---Collects the `User` events of sven that fire while `fn` runs.
---@param fn fun()
---@return { name: string, data: table|nil }[]
function M.capture_events(fn)
  local events = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "Sven*",
    callback = function(args)
      table.insert(events, { name = args.match, data = args.data })
    end,
  })

  local ok, err = pcall(fn)
  vim.api.nvim_del_autocmd(id)

  if not ok then
    error(err, 0)
  end

  return events
end

---@param events { name: string }[]
---@param name string
---@return table|nil event The first event of that name
function M.event(events, name)
  for _, event in ipairs(events) do
    if event.name == name then
      return event
    end
  end
end

---A working copy with a conflict in `b.txt`: changed to "hello from elsewhere" in the
---repository (r3) and to "hello from here" locally. `svn update` has been run, so the file
---contains conflict markers.
---@param wc SvnHarnessWorkingCopy
---@return SvnHarnessWorkingCopy other The working copy the incoming change was committed from
function M.make_conflict(wc)
  local other = wc:checkout()
  other:replace("b.txt", "hello", "hello from elsewhere")
  other:commit("Change b.txt elsewhere")

  wc:replace("b.txt", "hello", "hello from here")
  wc:update()

  return other
end

return M
