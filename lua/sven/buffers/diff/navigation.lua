local api = vim.api

---Cursor movement and lookups shared by the buffers that render diffs with the `Diff` and `Hunk`
---components: the diff buffer and the revision view.
local M = {}

---@class SvenDiffLocation
---@field file string The file of the diff, as the diff names it
---@field new integer Line in the new version of the file
---@field old integer Line in the old version of the file
---@field line string|nil The diff line under the cursor, with its `+`, `-` or ` ` prefix. nil on a header
---@field diff Diff|nil
---@field hunk Hunk|nil

---Translates a position inside a hunk to line numbers of the file.
---@param hunk Hunk
---@param offset integer 0 for the hunk header, 1 for the first line of `hunk.lines`, ...
---@return integer old Line in the old version
---@return integer new Line in the new version
function M.hunk_location(hunk, offset)
  local old, new = hunk.index_from, hunk.disk_from

  for i = 1, math.min(offset, #hunk.lines) - 1 do
    local operand = hunk.lines[i]:sub(1, 1)
    if operand == "+" then
      new = new + 1
    elseif operand == "-" then
      old = old + 1
    elseif operand ~= "\\" then
      old = old + 1
      new = new + 1
    end
  end

  return math.max(old, 1), math.max(new, 1)
end

---What the cursor is on in a buffer that renders diffs: a line of a hunk, a hunk header or the
---header of a file.
---@param buffer Buffer
---@return SvenDiffLocation|nil
function M.location_under_cursor(buffer)
  local hunk_component = buffer.ui:get_component_under_cursor(function(c)
    return c.options.hunk ~= nil
  end)

  local diff_component = buffer.ui:get_component_under_cursor(function(c)
    return c.options.diff ~= nil
  end)
  local diff = diff_component and diff_component.options.diff or nil

  if hunk_component then
    local hunk = hunk_component.options.hunk
    local offset = buffer:cursor_line() - hunk_component.position.row_start
    local old, new = M.hunk_location(hunk, offset)

    return {
      file = vim.trim(hunk.file or (diff and diff.file) or ""),
      old = old,
      new = new,
      line = offset >= 1 and hunk.lines[offset] or nil,
      diff = diff,
      hunk = hunk,
    }
  end

  if diff then
    return { file = diff.file, old = 1, new = 1, diff = diff }
  end
end

---@param c Component
---@return boolean
local function is_diff_or_hunk(c)
  return c.options.tag == "Diff" or c.options.tag == "Hunk"
end

---Moves the cursor to the header of the hunk (or file) above it
---@param buffer Buffer
function M.goto_previous_hunk_header(buffer)
  local function previous_hunk_header(line)
    local c = buffer.ui:get_component_on_line(line, is_diff_or_hunk)

    if c then
      local first, _ = c:row_range_abs()
      if vim.fn.line(".") == first then
        first = previous_hunk_header(line - 1)
      end

      return first
    end
  end

  local previous_header = previous_hunk_header(vim.fn.line("."))
  if previous_header then
    api.nvim_win_set_cursor(0, { previous_header, 0 })
    vim.cmd("normal! zt")
  end
end

---Moves the cursor to the header of the next hunk (or file)
---@param buffer Buffer
function M.goto_next_hunk_header(buffer)
  local c = buffer.ui:get_component_under_cursor(is_diff_or_hunk)

  if c then
    if c.options.tag == "Diff" then
      buffer:move_cursor(vim.fn.line(".") + 1)
    else
      local _, last = c:row_range_abs()
      if last == vim.fn.line("$") then
        buffer:move_cursor(last)
      else
        buffer:move_cursor(last + 1)
      end
    end
    vim.cmd("normal! zt")
  end
end

---The `value` option of the row of an overview the cursor is on.
---@param buffer Buffer
---@param tag string The tag of the rows: "OverviewFile" in the diff buffer, "ChangedPath" in the revision view
---@return any|nil
function M.overview_value_under_cursor(buffer, tag)
  local component = buffer.ui:get_component_under_cursor(function(c)
    return c.options.tag == tag
  end)

  return component and component.options.value or nil
end

---Moves the cursor to where the diff of a file starts
---@param buffer Buffer
---@param file string `diff.file`
---@return boolean moved false when the buffer has no diff of that file
function M.goto_diff(buffer, file)
  local line = M.diff_header_line(buffer, file)
  if not line then
    return false
  end

  -- Save position in jumplist
  vim.cmd("normal! m'")
  buffer:move_cursor(line)

  return true
end

---@param component Component
---@param f fun(c: Component): boolean
---@return Component|nil
local function find_component(component, f)
  if f(component) then
    return component
  end

  for _, child in ipairs(component.children or {}) do
    local found = find_component(child, f)
    if found then
      return found
    end
  end
end

---Finds the line a file's diff starts on
---@param buffer Buffer
---@param file string `diff.file`
---@return integer|nil
function M.diff_header_line(buffer, file)
  local component = find_component(buffer.ui.layout, function(c)
    return c.options ~= nil and c.options.diff ~= nil and c.options.diff.file == file
  end)

  if component then
    local first, _ = component:row_range_abs()
    return first
  end
end

return M
