local Buffer = require("sven.lib.buffer")
local config = require("sven.config")
local input = require("sven.lib.input")
local util = require("sven.lib.util")
local svn = require("sven.lib.svn")
local logger = require("sven.logger")
local event = require("sven.lib.event")
local notification = require("sven.lib.notification")
local a = require("sven.lib.async")

local pad = util.pad_right

local COMMENT_CHAR = "#"

---A buffer to write a commit message in. It looks and behaves like Neogit's commit editor, but
---instead of serving as git's `$GIT_EDITOR` it edits a temporary file and hands the message to
---a callback:
---
---  require("sven.buffers.editor")
---    .new({
---      comments = { "Changes to be committed:", "  M src/main.c" },
---      on_done = function(message)
---        if message then
---          -- submitted: commit with it
---        else
---          -- aborted
---        end
---      end,
---    })
---    :open()
---
---or, inside an async context (popup actions run in one):
---
---  local message = require("sven.buffers.editor").edit { comments = { ... } }
---  if message then ... end
---
---The message is submitted with the `Submit` mapping (`<c-c><c-c>`), `ZZ` or by writing and
---closing the buffer (`:wq`). It is aborted with `Abort` (`<c-c><c-k>`), `ZQ`, by closing the
---buffer without writing (`:q!`), or by submitting an empty message. `Close` (`q`) submits what
---was saved and asks about unsaved changes. `PrevMessage`/`NextMessage` (`<m-p>`/`<m-n>`) cycle
---through the messages of the recent log entries.
---
---Everything from the generated comment block (lines starting with `#`) to the end of the
---buffer is not part of the message.
---@class EditorBuffer
---@field opts SvenEditorOpts
---@field filename string The temporary file the message is edited in
---@field buffer Buffer|nil
---@field footer string[] The generated comment block
---@field diff_view { close: fun(self: table) }|nil
local M = {}

---@class SvenEditorOpts
---@field message? string|string[] Initial message, e.g. the message of a commit that failed
---@field comments? string[] Lines to show below the help, commented out. For example the files that are going to be committed
---@field on_done? fun(message: string|nil) Called exactly once when the editor is closed: with the message when it was submitted, with nil when it was aborted
---@field diff_view? fun(): { close: fun(self: table) }|nil Opens a view (e.g. the staged diff) next to the editor. It is closed together with the editor. Not called for floating editors
---@field allow_empty? boolean Submit an empty message instead of treating it as an abort
---@field kind? WindowKind How to open the editor. Defaults to `config.commit_editor.kind`

---@param line string
---@return boolean
local function is_comment(line)
  return vim.startswith(line, COMMENT_CHAR)
end

---Extracts the message from the lines of the editor buffer: the generated comment block and any
---comment or blank lines at the end are dropped, as are blank lines at the start.
---@param lines string[]
---@param footer string[]|nil The generated comment block. Removed wherever it is
---@return string message "" when nothing but comments is left
function M.extract_message(lines, footer)
  lines = vim.deepcopy(lines)

  -- The generated block is removed even when something was written below it
  if footer and #footer > 0 then
    for start = #lines - #footer + 1, 1, -1 do
      local matches = true
      for offset = 1, #footer do
        if lines[start + offset - 1] ~= footer[offset] then
          matches = false
          break
        end
      end

      if matches then
        for _ = 1, #footer do
          table.remove(lines, start)
        end
        break
      end
    end
  end

  while #lines > 0 and (vim.trim(lines[#lines]) == "" or is_comment(lines[#lines])) do
    table.remove(lines)
  end

  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end

  return table.concat(lines, "\n")
end

--- Creates a new EditorBuffer
---@param opts SvenEditorOpts|nil
---@return EditorBuffer
function M.new(opts)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  -- The name Neovim gives the buffer, with symlinks resolved
  dir = vim.uv.fs_realpath(dir) or dir

  local instance = {
    opts = opts or {},
    filename = vim.fs.joinpath(dir, "SVEN_COMMIT_EDITMSG"),
    buffer = nil,
    footer = {},
    diff_view = nil,
  }

  setmetatable(instance, { __index = M })

  return instance
end

---Opens an editor and waits until it is closed. Must be called inside an async context.
---Returns the message when it was submitted, nil when the editor was aborted.
---@type fun(opts: SvenEditorOpts|nil): string|nil
M.edit = a.wrap(function(opts, callback)
  opts = vim.tbl_extend("force", {}, opts or {})

  local on_done = opts.on_done
  opts.on_done = function(message)
    if on_done then
      on_done(message)
    end

    callback(message)
  end

  -- The UI may only be touched from the main loop
  vim.schedule(function()
    M.new(opts):open()
  end)
end, 2)

---@return string[] The generated comment block: help for the mappings, then the caller's comments
function M:build_footer()
  local mapping = config.get_reversed_commit_editor_maps()

  -- Populate help lines with mappings for buffer
  local padding = util.max_length(util.flatten(vim.tbl_values(mapping)))
  local pad_mapping = function(name)
    local keys = mapping[name]
    return pad(type(keys) == "table" and keys[1] or "<NOP>", padding)
  end

  -- stylua: ignore
  local help_lines = {
    ("%s"):format(COMMENT_CHAR),
    ("%s Commands:"):format(COMMENT_CHAR),
    ("%s   %s Close"):format(COMMENT_CHAR, pad_mapping("Close")),
    ("%s   %s Submit"):format(COMMENT_CHAR, pad_mapping("Submit")),
    ("%s   %s Abort"):format(COMMENT_CHAR, pad_mapping("Abort")),
    ("%s   %s Previous Message"):format(COMMENT_CHAR, pad_mapping("PrevMessage")),
    ("%s   %s Next Message"):format(COMMENT_CHAR, pad_mapping("NextMessage")),
    ("%s   %s Reset Message"):format(COMMENT_CHAR, pad_mapping("ResetMessage")),
  }

  help_lines = util.filter_map(help_lines, function(line)
    if not line:match("<NOP>") then -- mapping will be <NOP> if user unbinds key
      return line
    end
  end)

  local footer = help_lines
  vim.list_extend(footer, {
    COMMENT_CHAR,
    ("%s Please enter the commit message for your changes. This comment block"):format(COMMENT_CHAR),
    ("%s is ignored, and an empty message aborts the commit."):format(COMMENT_CHAR),
  })

  if self.opts.comments and #self.opts.comments > 0 then
    table.insert(footer, COMMENT_CHAR)
    for _, line in ipairs(self.opts.comments) do
      for _, part in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(footer, part == "" and COMMENT_CHAR or ("%s %s"):format(COMMENT_CHAR, part))
      end
    end
  end

  table.insert(footer, COMMENT_CHAR)

  return footer
end

---@return string[]
function M:initial_message()
  local message = self.opts.message or ""
  if type(message) == "string" then
    message = vim.split(message, "\n", { plain = true })
  end

  if #message == 0 then
    message = { "" }
  end

  return vim.deepcopy(message)
end

---Removes the temporary file and its directory
function M:cleanup()
  os.remove(self.filename)
  vim.uv.fs_rmdir(vim.fs.dirname(self.filename))
end

---@param kind WindowKind|nil Defaults to `config.commit_editor.kind`
function M:open(kind)
  kind = kind or self.opts.kind or config.values.commit_editor.kind
  assert(kind, "Editor must specify a kind")
  logger.debug("[EDITOR] Opening editor as " .. kind)

  local mapping = config.get_reversed_commit_editor_maps()
  local mapping_I = config.get_reversed_commit_editor_maps_I()

  -- How the editor ends: nil while undecided, which means "whatever was written to the file"
  local aborted = false
  local submitted = false
  -- Whether the user wrote the buffer, as opposed to the writes done while setting it up
  local written = false
  local ready = false

  local message_index = 1
  local message_buffer = { self:initial_message() }

  self.footer = self:build_footer()
  local footer = self.footer

  -- The buffer is loaded from this file
  local content = self:initial_message()
  table.insert(content, "")
  vim.list_extend(content, footer)
  vim.fn.writefile(content, self.filename)

  ---Messages of earlier commits, newest first. Index 2 is the most recent one.
  local function log_message(index)
    local entry = svn.repo.state.recent.items[index - 1]
    return entry and vim.deepcopy(entry.description) or { "" }
  end

  local function commit_message()
    return message_buffer[message_index] or log_message(message_index)
  end

  local function current_message(buffer)
    local message = buffer:get_lines(0, -1)
    -- Everything above the generated comment block, minus the blank line that separates them
    message = util.slice(message, 1, math.max(1, #message - #footer - 1))

    return message
  end

  local function submit(buffer)
    submitted = true
    buffer:write()
    buffer:close(true)
  end

  local function abort(buffer)
    aborted = true
    buffer:write()
    buffer:close(true)
  end

  self.buffer = Buffer.create {
    name = self.filename,
    filetype = "gitcommit",
    load = true,
    spell_check = config.values.commit_editor.spell_check,
    buftype = "",
    kind = kind,
    modifiable = true,
    disable_line_numbers = config.values.disable_line_numbers,
    disable_relative_line_numbers = config.values.disable_relative_line_numbers,
    status_column = not config.values.disable_signs and "" or nil,
    readonly = false,
    autocmds = {
      ["BufWritePost"] = function()
        if ready then
          written = true
        end
      end,
      ["QuitPre"] = function() -- For :wq compatibility
        if self.diff_view then
          self.diff_view:close()
          self.diff_view = nil
        end
      end,
    },
    on_detach = function()
      logger.debug("[EDITOR] Cleaning Up")

      local message = nil
      if not aborted and (submitted or written) then
        local ok, lines = pcall(vim.fn.readfile, self.filename)
        message = M.extract_message(ok and lines or {}, footer)

        if message == "" and not self.opts.allow_empty then
          notification.info("Aborting commit due to empty commit message")
          message = nil
        end
      end

      self:cleanup()

      if self.diff_view then
        logger.debug("[EDITOR] Closing diff view")
        self.diff_view:close()
        self.diff_view = nil
      end

      event.send("EditorClosed")

      if self.opts.on_done then
        logger.debug("[EDITOR] Running on_done callback")
        local on_done = self.opts.on_done
        self.opts.on_done = nil
        -- Scheduled, so that the callback runs once the editor window is gone
        vim.schedule(function()
          on_done(message)
        end)
      end

      logger.debug("[EDITOR] Done cleaning up")
    end,
    after = function(buffer)
      -- Writing once with a bang ties the buffer to its file. Without it a plain `:w` or `:wq`
      -- is refused, because the file exists and the buffer was not read from it.
      buffer:write()
      buffer:set_buffer_option("modified", false)
      buffer:move_cursor(1)

      -- Start insert mode if user has configured it
      local disable_insert = config.values.disable_insert_on_commit
      if
        (disable_insert == "auto" and vim.fn.prevnonblank(".") ~= vim.fn.line("."))
        or not disable_insert
      then
        vim.cmd(":startinsert")
      end

      if self.opts.diff_view and kind ~= "floating" then
        logger.debug("[EDITOR] Opening diff view")
        self.diff_view = self.opts.diff_view()
      end

      ready = true
    end,
    mappings = {
      i = {
        [mapping_I["Submit"]] = function(buffer)
          logger.debug("[EDITOR] Action I: Submit")
          vim.cmd.stopinsert()
          submit(buffer)
        end,
        [mapping_I["Abort"]] = function(buffer)
          logger.debug("[EDITOR] Action I: Abort")
          vim.cmd.stopinsert()
          abort(buffer)
        end,
      },
      n = {
        [mapping["Close"]] = function(buffer)
          logger.debug("[EDITOR] Action N: Close")
          if buffer:get_option("modified") then
            if input.get_confirmation("Save changes?") then
              submit(buffer)
            else
              abort(buffer)
            end
          elseif written then
            submit(buffer)
          else
            abort(buffer)
          end
        end,
        [mapping["Submit"]] = function(buffer)
          logger.debug("[EDITOR] Action N: Submit")
          submit(buffer)
        end,
        [mapping["Abort"]] = function(buffer)
          logger.debug("[EDITOR] Action N: Abort")
          abort(buffer)
        end,
        ["ZZ"] = function(buffer)
          logger.debug("[EDITOR] Action N: ZZ (submit)")
          submit(buffer)
        end,
        ["ZQ"] = function(buffer)
          logger.debug("[EDITOR] Action N: ZQ (abort)")
          abort(buffer)
        end,
        [mapping["PrevMessage"]] = function(buffer)
          logger.debug("[EDITOR] Action N: PrevMessage")
          local message = current_message(buffer)
          message_buffer[message_index] = message

          message_index = message_index + 1

          buffer:set_lines(0, #message, false, commit_message())
          buffer:move_cursor(1)
        end,
        [mapping["NextMessage"]] = function(buffer)
          logger.debug("[EDITOR] Action N: NextMessage")
          local message = current_message(buffer)

          if message_index > 1 then
            message_buffer[message_index] = message
            message_index = message_index - 1
          end

          buffer:set_lines(0, #message, false, commit_message())
          buffer:move_cursor(1)
        end,
        [mapping["ResetMessage"]] = function(buffer)
          logger.debug("[EDITOR] Action N: ResetMessage")
          local message = current_message(buffer)
          buffer:set_lines(0, #message, false, log_message(message_index))
          buffer:move_cursor(1)
        end,
      },
    },
  }
end

return M
