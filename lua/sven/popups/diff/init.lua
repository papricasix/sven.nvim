local M = {}

local popup = require("sven.lib.popup")
local actions = require("sven.popups.diff.actions")
local inline = require("sven.buffers.diff.inline")
local Env = require("sven.popups.diff.env")

---What the "do what I mean" action is going to show, for its label
---@param env SvenPopupContext
---@return string
local function this(env)
  if env.revision and env.file then
    return ("r%d of %s"):format(env.revision, vim.fs.basename(env.file))
  elseif env.revision then
    return ("r%d"):format(env.revision)
  elseif #env.paths > 1 then
    return ("%d paths"):format(#env.paths)
  elseif env.file then
    return vim.fs.basename(env.file)
  elseif env.section and env.section.name == "staged" then
    return "staged"
  end

  return "working copy"
end

---Opens the diff popup.
---@param env table|nil Where the popup is opened from: `revision` (the revision under the cursor), `paths` (relative to the working copy root), `item` and `section` of the status buffer. Without paths, "this file" is the file of the current buffer
---@return PopupData
function M.create(env)
  env = Env.resolve(env)

  local inline_shown = #inline.buffers() > 0

  local p = popup
    .builder()
    :name("SvenDiffPopup")
    :switch("w", "extensions=-w", "Ignore whitespace")
    :switch("p", "ignore-properties", "Ignore property changes")
    :group_heading("Diff")
    :action("d", this(env), actions.this)
    :action("w", "working copy", actions.working)
    :action("s", "staged", actions.staged)
    :new_action_group("Revisions")
    :action("r", "revision", actions.revision)
    :action_if(env.file ~= nil, "f", "file in revision", actions.file_revision)
    :action("R", "range", actions.range)
    :new_action_group_if(inline_shown, "Inline")
    :action_if(inline_shown, "x", "clear", actions.clear_inline)
    :env(env)
    :build()

  p:show()

  return p
end

return M
