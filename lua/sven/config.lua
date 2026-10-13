local util = require("sven.lib.util")
local M = {}

local mappings = {}

---Returns a map of commands, mapped to the list of keys which trigger them.
---@return table<string, string[]>
local function get_reversed_maps(set)
  if not mappings[set] then
    local result = {}
    for k, v in pairs(M.values.mappings[set] or {}) do
      -- If `v == false` the mapping is disabled
      if v then
        local current = result[v]
        if current then
          table.insert(current, k)
        else
          result[v] = { k }
        end
      end
    end

    setmetatable(result, {
      __index = function()
        return "<nop>"
      end,
    })

    mappings[set] = result
  end

  return mappings[set]
end

---@return table<string, string[]>
function M.get_reversed_status_maps()
  return get_reversed_maps("status")
end

---@return table<string, string[]>
function M.get_reversed_popup_maps()
  return get_reversed_maps("popup")
end

---@return table<string, string[]>
function M.get_reversed_commit_editor_maps()
  return get_reversed_maps("commit_editor")
end

---@return table<string, string[]>
function M.get_reversed_commit_editor_maps_I()
  return get_reversed_maps("commit_editor_I")
end

---Mappings of the revision view (the svn counterpart of Neogit's commit view).
---@return table<string, string[]>
function M.get_reversed_commit_view_maps()
  return get_reversed_maps("commit_view")
end

---@param set string
---@return table<string, string[]>
function M.get_user_mappings(set)
  local mappings = {}

  for k, v in pairs(get_reversed_maps(set)) do
    if type(k) == "function" then
      for _, trigger in ipairs(v) do
        mappings[trigger] = k
      end
    end
  end

  return mappings
end

---@alias WindowKind
---| "replace" Like :enew
---| "tab" Open in a new tab
---| "split" Open in a split
---| "split_above" Like :top split
---| "split_above_all" Like :top split
---| "split_below" Like :below split
---| "split_below_all" Like :below split
---| "vsplit" Open in a vertical split
---| "floating" Open in a floating window
---| "floating_console" Open in a floating window across the bottom of the screen
---| "popup" Open in a popup
---| "auto" vsplit if window would have 80 cols, otherwise split

---@class SvenCommitBufferConfig Revision buffer options
---@field kind WindowKind The type of window that should be opened

---@class SvenConfigPopup Popup window options
---@field kind WindowKind The type of window that should be opened
---@field show_title boolean Show a title for the popup

---@class SvenConfigFloating
---@field relative? string
---@field width? number
---@field height? number
---@field col? number
---@field row? number
---@field style? string
---@field border? string

---@alias StagedDiffSplitKind
---| "split" Open in a split
---| "vsplit" Open in a vertical split
---| "split_above" Like :top split
---| "auto" "vsplit" if window would have 80 cols, otherwise "split"

---@class SvenCommitEditorConfigPopup Popup window options
---@field kind WindowKind The type of window that should be opened
---@field show_staged_diff? boolean Display staged changes in a buffer when committing
---@field staged_diff_split_kind? StagedDiffSplitKind Whether to show staged changes in a vertical or horizontal split
---@field spell_check? boolean Enable/Disable spell checking

---@alias SvenConfigSignsIcon { [1]: string, [2]: string }

---@class SvenConfigSigns
---@field hunk SvenConfigSignsIcon The icons to use for open and closed hunks
---@field item SvenConfigSignsIcon The icons to use for open and closed items
---@field section SvenConfigSignsIcon The icons to use for open and closed sections

---@class SvenConfigSection A section to show in the Sven Status buffer, e.g. Staged/Changes/Unversioned
---@field folded boolean Whether or not this section should be open or closed by default
---@field hidden boolean Whether or not this section should be shown

---@class SvenConfigSections
---@field conflicts SvenConfigSection|nil Conflicted files (text, property and tree conflicts)
---@field unversioned SvenConfigSection|nil Unversioned files and directories
---@field changes SvenConfigSection|nil Versioned changes that are in no changelist
---@field staged SvenConfigSection|nil Members of the staging changelist
---@field changelists SvenConfigSection|nil Applies to the section of every other changelist
---@field recent SvenConfigSection|nil Recent log entries

---@class HighlightOptions
---@field italic?     boolean
---@field bold?       boolean
---@field underline?  boolean
---@field bg0?        string  Darkest background color
---@field bg1?        string  Second darkest background color
---@field bg2?        string  Second lightest background color
---@field bg3?        string  Lightest background color
---@field grey?       string  middle grey shade for foreground
---@field white?      string  Foreground white (main text)
---@field red?        string  Foreground red
---@field bg_red?     string  Background red
---@field line_red?   string  Cursor line highlight for red regions, like deleted hunks
---@field orange?     string  Foreground orange
---@field bg_orange?  string  background orange
---@field yellow?     string  Foreground yellow
---@field bg_yellow?  string  background yellow
---@field green?      string  Foreground green
---@field bg_green?   string  Background green
---@field line_green? string  Cursor line highlight for green regions, like added hunks
---@field cyan?       string  Foreground cyan
---@field bg_cyan?    string  Background cyan
---@field blue?       string  Foreground blue
---@field bg_blue?    string  Background blue
---@field purple?     string  Foreground purple
---@field bg_purple?  string  Background purple
---@field md_purple?  string  Background _medium_ purple. Lighter than bg_purple. Used for hunk headers.

---@class SvenFilewatcherConfig
---@field enabled boolean

---@alias SvenConfigMappingsFinder
---| "Select"
---| "Close"
---| "Next"
---| "Previous"
---| "CopySelection"
---| "MultiselectToggleNext"
---| "MultiselectTogglePrevious"
---| "InsertCompletion"
---| "NOP"
---| "ScrollWheelDown"
---| "ScrollWheelUp"
---| "MouseClick"
---| false

---@alias SvenConfigMappingsStatus
---| "Close"
---| "MoveDown"
---| "MoveUp"
---| "OpenTree"
---| "OpenFold"
---| "CloseFold"
---| "Command"
---| "Depth1"
---| "Depth2"
---| "Depth3"
---| "Depth4"
---| "Toggle"
---| "Discard"
---| "Stage"
---| "StageUnstaged"
---| "StageAll"
---| "Unstage"
---| "UnstageStaged"
---| "Blame"
---| "RefreshBuffer"
---| "GoToFile"
---| "PeekFile"
---| "VSplitOpen"
---| "SplitOpen"
---| "TabOpen"
---| "GoToPreviousHunkHeader"
---| "GoToNextHunkHeader"
---| "CommandHistory"
---| "YankSelected"
---| "OpenOrScrollUp"
---| "OpenOrScrollDown"
---| "PeekUp"
---| "PeekDown"
---| "NextSection"
---| "PreviousSection"
---| false
---| fun()

---@alias SvenConfigMappingsPopup
---| "HelpPopup"
---| "CommitPopup"
---| "LogPopup"
---| "DiffPopup"
---| "UpdatePopup"
---| "ResolvePopup"
---| false

---@alias SvenConfigMappingsCommitEditor
---| "Close"
---| "Submit"
---| "Abort"
---| "PrevMessage"
---| "ResetMessage"
---| "NextMessage"
---| false
---| fun()

---@alias SvenConfigMappingsCommitEditor_I
---| "Submit"
---| "Abort"
---| false
---| fun()

---@alias SvenConfigMappingsCommitView
---| "OpenFileInWorktree"
---| false
---| fun()

---@alias SvenHook string Name of a hook. No hooks are fired by the foundation; views may define their own.

---@class SvenConfigStatusOptions
---@field recent_commit_count? integer The number of recent log entries to display
---@field mode_padding? integer The amount of padding to add to the right of the mode column
---@field HEAD_padding? integer The amount of padding to add to the right of the header labels
---@field HEAD_folded? boolean Whether or not the header section should be open or closed by default
---@field mode_text? { [string]: string } The text to display for each mode (the single letter svn prints)

---@class SvenConfigMappings Consult the config file or documentation for values
---@field finder? { [string]: SvenConfigMappingsFinder } A dictionary that uses finder commands to set multiple keybinds
---@field status? { [string]: SvenConfigMappingsStatus } A dictionary that uses status commands to set a single keybind
---@field popup? { [string]: SvenConfigMappingsPopup } A dictionary that uses popup commands to set a single keybind
---@field commit_editor? { [string]: SvenConfigMappingsCommitEditor } A dictionary that uses Commit editor commands to set a single keybind
---@field commit_editor_I? { [string]: SvenConfigMappingsCommitEditor_I } A dictionary that uses Commit editor commands to set a single keybind
---@field commit_view? { [string]: SvenConfigMappingsCommitView } A dictionary that uses revision view commands to set a single keybind

---@class SvenConfig Sven configuration settings
---@field filewatcher? SvenFilewatcherConfig Values for filewatcher
---@field svn_executable? string Path to svn executable (defaults to "svn")
---@field staging_changelist? string Name of the svn changelist that acts as the staging area (defaults to "sven-staged")
---@field commit_date_format? string Revision date format (strftime)
---@field log_date_format? string Log date format (strftime). Relative dates are shown when nil
---@field log_pager? [string] Log pager
---@field disable_hint? boolean Remove the top hint in the Status buffer
---@field disable_context_highlighting? boolean Disable context highlights based on cursor position
---@field disable_signs? boolean Special signs to draw for sections etc. in Sven
---@field telescope_sorter? function The sorter telescope will use
---@field process_spinner? boolean Hide/Show the process spinner
---@field disable_insert_on_commit? boolean|"auto" Disable automatically entering insert mode in commit dialogues
---@field use_per_project_settings? boolean Scope persisted settings on a per-project basis
---@field remember_settings? boolean Whether sven should persist flags from popups, e.g. log flags
---@field kind? WindowKind The default type of window sven should open in
---@field floating? SvenConfigFloating The floating window style
---@field disable_line_numbers? boolean Whether to disable line numbers
---@field disable_relative_line_numbers? boolean Whether to disable line numbers
---@field console_timeout? integer Time in milliseconds after a console is created for long running commands
---@field auto_show_console? boolean Automatically show the console if a command takes longer than console_timeout
---@field auto_show_console_on? string Specify "output" (show always; default) or "error" if `auto_show_console` enabled
---@field auto_close_console? boolean Automatically hide the console if the process exits with a 0 status
---@field status? SvenConfigStatusOptions Status buffer options
---@field commit_editor? SvenCommitEditorConfigPopup Commit editor options
---@field commit_select_view? SvenConfigPopup Revision select view options
---@field commit_view? SvenCommitBufferConfig Revision buffer options
---@field log_view? SvenConfigPopup Log view options
---@field preview_buffer? SvenConfigPopup Preview options
---@field popup? SvenConfigPopup Set the default way of opening popups
---@field signs? SvenConfigSigns Signs used for toggled regions
---@field integrations? { telescope: boolean, fzf_lua: boolean, mini_pick: boolean, snacks: boolean } Which integrations to enable
---@field sections? SvenConfigSections
---@field ignored_settings? string[] Settings to never persist, format: "Filetype--cli-value", i.e. "SvenLogPopup--limit"
---@field mappings? SvenConfigMappings
---@field notification_icon? string
---@field use_default_keymaps? boolean
---@field highlight? HighlightOptions
---@field treesitter_diff_highlight? boolean Apply syntax highlighting to diff hunks via treesitter
---@field word_diff_highlight? boolean Apply word-diff highlighting to diff hunks
---@field builders? { [string]: fun(builder: PopupBuilder) }
---@field hooks? { [SvenHook]: fun(data: table?) }

---Returns the default Sven configuration
---@return SvenConfig
function M.get_default_values()
  return {
    use_default_keymaps = true,
    disable_hint = false,
    disable_context_highlighting = false,
    disable_signs = false,
    treesitter_diff_highlight = false,
    word_diff_highlight = true,
    commit_date_format = nil,
    log_date_format = nil,
    log_pager = nil,
    process_spinner = false,
    hooks = {},
    filewatcher = {
      enabled = true,
    },
    telescope_sorter = function()
      return nil
    end,
    highlight = {},
    svn_executable = "svn",
    -- svn has no index. A file is "staged" when it is a member of this changelist.
    staging_changelist = "sven-staged",
    disable_insert_on_commit = "auto",
    use_per_project_settings = true,
    remember_settings = true,
    kind = "tab",
    floating = {
      relative = "editor",
      width = 0.8,
      height = 0.7,
      style = "minimal",
      border = "rounded",
    },
    disable_line_numbers = true,
    disable_relative_line_numbers = true,
    -- The time after which an output console is shown for slow running commands
    console_timeout = 2000,
    -- Automatically show console if a command takes more than console_timeout milliseconds
    auto_show_console = true,
    -- If `auto_show_console` is enabled, specify "output" (default) to show
    -- the console always, or "error" to auto-show the console only on error
    auto_show_console_on = "output",
    auto_close_console = true,
    notification_icon = "⑂",
    status = {
      recent_commit_count = 10,
      HEAD_padding = 10,
      HEAD_folded = false,
      mode_padding = 3,
      -- Keyed by the single letter `svn status` prints in its first column
      mode_text = {
        M = "modified",
        A = "added",
        D = "deleted",
        R = "replaced",
        C = "conflicted",
        X = "external",
        I = "ignored",
        ["!"] = "missing",
        ["~"] = "obstructed",
        ["?"] = "",
      },
    },
    commit_editor = {
      kind = "tab",
      show_staged_diff = true,
      staged_diff_split_kind = "split",
      spell_check = true,
    },
    commit_select_view = {
      kind = "tab",
    },
    commit_view = {
      kind = "vsplit",
    },
    log_view = {
      kind = "tab",
    },
    preview_buffer = {
      kind = "floating_console",
    },
    popup = {
      kind = "popup",
      show_title = false,
    },
    signs = {
      hunk = { "", "" },
      item = { ">", "v" },
      section = { ">", "v" },
    },
    integrations = {
      telescope = nil,
      fzf_lua = nil,
      mini_pick = nil,
      snacks = nil,
    },
    sections = {
      conflicts = {
        folded = false,
        hidden = false,
      },
      unversioned = {
        folded = false,
        hidden = false,
      },
      changes = {
        folded = false,
        hidden = false,
      },
      staged = {
        folded = false,
        hidden = false,
      },
      changelists = {
        folded = false,
        hidden = false,
      },
      recent = {
        folded = true,
        hidden = false,
      },
    },
    ignored_settings = {},
    mappings = {
      commit_view = {
        ["a"] = "OpenFileInWorktree",
      },
      commit_editor = {
        ["q"] = "Close",
        ["<c-c><c-c>"] = "Submit",
        ["<c-c><c-k>"] = "Abort",
        ["<m-p>"] = "PrevMessage",
        ["<m-n>"] = "NextMessage",
        ["<m-r>"] = "ResetMessage",
      },
      commit_editor_I = {
        ["<c-c><c-c>"] = "Submit",
        ["<c-c><c-k>"] = "Abort",
      },
      finder = {
        ["<cr>"] = "Select",
        ["<c-c>"] = "Close",
        ["<esc>"] = "Close",
        ["<c-n>"] = "Next",
        ["<c-p>"] = "Previous",
        ["<down>"] = "Next",
        ["<up>"] = "Previous",
        ["<tab>"] = "InsertCompletion",
        ["<c-y>"] = "CopySelection",
        ["<space>"] = "MultiselectToggleNext",
        ["<s-space>"] = "MultiselectTogglePrevious",
        ["<c-j>"] = "NOP",
        ["<ScrollWheelDown>"] = "ScrollWheelDown",
        ["<ScrollWheelUp>"] = "ScrollWheelUp",
        ["<ScrollWheelLeft>"] = "NOP",
        ["<ScrollWheelRight>"] = "NOP",
        ["<LeftMouse>"] = "MouseClick",
        ["<2-LeftMouse>"] = "NOP",
      },
      popup = {
        ["?"] = "HelpPopup",
        ["c"] = "CommitPopup",
        ["d"] = "DiffPopup",
        ["l"] = "LogPopup",
        ["F"] = "UpdatePopup",
        ["r"] = "ResolvePopup",
      },
      status = {
        ["j"] = "MoveDown",
        ["k"] = "MoveUp",
        ["o"] = "OpenTree",
        ["q"] = "Close",
        ["1"] = "Depth1",
        ["2"] = "Depth2",
        ["3"] = "Depth3",
        ["4"] = "Depth4",
        ["Q"] = "Command",
        ["<tab>"] = "Toggle",
        ["za"] = "Toggle",
        ["zo"] = "OpenFold",
        ["zc"] = "CloseFold",
        ["zC"] = "Depth1",
        ["zO"] = "Depth4",
        ["x"] = "Discard",
        ["s"] = "Stage",
        ["S"] = "StageUnstaged",
        ["<c-s>"] = "StageAll",
        ["u"] = "Unstage",
        ["U"] = "UnstageStaged",
        ["B"] = "Blame",
        ["$"] = "CommandHistory",
        ["Y"] = "YankSelected",
        ["<c-r>"] = "RefreshBuffer",
        ["<cr>"] = "GoToFile",
        ["<s-cr>"] = "PeekFile",
        ["<c-v>"] = "VSplitOpen",
        ["<c-x>"] = "SplitOpen",
        ["<c-t>"] = "TabOpen",
        ["{"] = "GoToPreviousHunkHeader",
        ["}"] = "GoToNextHunkHeader",
        ["[c"] = "OpenOrScrollUp",
        ["]c"] = "OpenOrScrollDown",
        ["<c-k>"] = "PeekUp",
        ["<c-j>"] = "PeekDown",
        ["<c-n>"] = "NextSection",
        ["<c-p>"] = "PreviousSection",
      },
    },
  }
end

M.values = M.get_default_values()

---Validates the config
---@return { [string]: string } all error messages emitted during validation
function M.validate_config()
  local config = M.values

  ---@type { [string]: string }
  local errors = {}
  local function err(value, msg)
    errors[value] = msg
  end

  ---Checks if a variable is the correct, type if not it calls err with an error string
  ---@param value any
  ---@param name string
  ---@param expected_types type | type[]
  local function validate_type(value, name, expected_types)
    if type(expected_types) == "table" then
      if not vim.tbl_contains(expected_types, type(value)) then
        err(
          name,
          string.format(
            "Expected `%s` to be one of types '%s', got '%s'",
            name,
            table.concat(expected_types, ", "),
            type(value)
          )
        )
        return false
      end
      return true
    end

    if type(value) ~= expected_types then
      err(
        name,
        string.format("Expected `%s` to be of type '%s', got '%s'", name, expected_types, type(value))
      )
      return false
    end
    return true
  end

  -- More complex validation functions go below
  local function validate_kind(val, name)
    if
      validate_type(val, name, "string")
      and not vim.tbl_contains({
        "split",
        "vsplit",
        "split_above",
        "split_above_all",
        "split_below",
        "split_below_all",
        "vsplit_left",
        "tab",
        "floating",
        "floating_console",
        "replace",
        "popup",
        "auto",
      }, val)
    then
      err(
        name,
        string.format(
          "Expected `%s` to be one of 'split', 'vsplit', 'split_above', 'split_above_all', 'split_below', 'split_below_all', 'vsplit_left', tab', 'floating', 'floating_console', 'replace', 'popup' or 'auto', got '%s'",
          name,
          val
        )
      )
    end
  end

  local function validate_signs()
    if not validate_type(config.signs, "signs", "table") then
      return
    end

    local function validate_signs_table(tbl_name, tbl)
      tbl_name = string.format("signs.%s", tbl_name)
      if type(tbl) ~= "table" then
        err(tbl_name, string.format("Expected `%s` to be of type 'table'!", tbl_name))
      else
        if #tbl ~= 2 then
          err(
            tbl_name,
            string.format("Expected for `%s` to be %s elements, it had %s elements!", tbl_name, #tbl, #tbl)
          )
        elseif type(tbl[1]) ~= "string" then
          err(
            tbl_name,
            string.format(
              "Expected element one of `%s` to be of type 'string', it was of type '%s'",
              tbl_name,
              tbl[1],
              type(tbl[1])
            )
          )
        elseif type(tbl[2]) ~= "string" then
          err(
            tbl_name,
            string.format(
              "Expected element two of `%s` to be of type 'string', it was of type '%s'",
              tbl_name,
              tbl[2],
              type(tbl[2])
            )
          )
        end
      end
    end

    validate_signs_table("hunk", config.signs.hunk)
    validate_signs_table("item", config.signs.item)
    validate_signs_table("section", config.signs.section)
  end

  local function validate_trinary_auto(value, name)
    local err_msg =
      string.format("Expected '%s' to be either a string with value 'auto' or a boolean value", name)
    if type(value) == "string" then
      if value ~= "auto" then
        err(name, err_msg)
      end
    elseif type(value) ~= "boolean" then
      err(name, err_msg)
    end
  end

  local function validate_integrations()
    local valid_integrations = { "telescope", "fzf_lua", "mini_pick", "snacks" }
    if not validate_type(config.integrations, "integrations", "table") or #config.integrations == 0 then
      return
    end
    for integration_name, _ in pairs(config.integrations) do
      if not vim.tbl_contains(valid_integrations, integration_name) then
        err(
          "valid_integrations." .. integration_name,
          string.format(
            "Expected a valid integration, received '%s', which is not a supported integration! Valid integrations: ",
            integration_name,
            table.concat(valid_integrations, ", ")
          )
        )
      end
    end
  end

  local function validate_sections()
    if not validate_type(config.sections, "sections", "table") then
      return
    end

    for section_name, section in pairs(config.sections) do
      validate_type(section, "section." .. section_name, "table")
      validate_type(section.folded, string.format("section.%s.folded", section_name), "boolean")
      validate_type(section.hidden, string.format("section.%s.hidden", section_name), "boolean")
    end
  end

  local function validate_highlights()
    if not validate_type(config.highlight, "highlight", "table") then
      return
    end

    for field, value in ipairs(config.highlight) do
      if field == "bold" or field == "italic" or field == "underline" then
        validate_type(value, string.format("highlight.%s", field), "boolean")
      else
        validate_type(value, string.format("highlight.%s", field), "string")

        if not string.match(value, "#%x%x%x%x%x%x") then
          err("highlight", string.format("Color value is not valid CSS: %s", value))
        end
      end
    end
  end

  local function validate_ignored_settings()
    if not validate_type(config.ignored_settings, "ignored_settings", "table") then
      return
    end

    for _, setting in ipairs(config.ignored_settings) do
      if validate_type(setting, "ignored_settings." .. vim.inspect(setting), "string") then
        local match_pattern = ".+%-%-.?"
        if not string.match(setting, match_pattern) then
          err(
            "ignored_settings",
            string.format(
              "An ignored_settings setting did not match %s (format: filetype--flag), setting was: %s",
              match_pattern,
              setting
            )
          )
        end
      end
    end
  end

  local function validate_staging_changelist()
    if not validate_type(config.staging_changelist, "staging_changelist", "string") then
      return
    end

    if config.staging_changelist == "" or config.staging_changelist:match("[\r\n]") then
      err(
        "staging_changelist",
        "Expected `staging_changelist` to be a non-empty, single line changelist name"
      )
    end
  end

  local function validate_mappings()
    if not validate_type(config.mappings, "mappings", "table") then
      return
    end

    -- Validate mappings.finder
    local valid_finder_commands = {
      false,
    }

    for _, cmd in pairs(M.get_default_values().mappings.finder) do
      table.insert(valid_finder_commands, cmd)
    end

    local function validate_finder_map(command, key)
      if
        not validate_type(key, string.format("mappings.finder -> %s", vim.inspect(key)), "string")
        or not validate_type(
          command,
          string.format("mappings.finder[%s]", vim.inspect(command)),
          { "string", "boolean" }
        )
      then
        return
      end

      if not vim.tbl_contains(valid_finder_commands, command) then
        local valid_finder_commands = util.map(valid_finder_commands, function(command)
          return vim.inspect(command)
        end)

        err(
          string.format("mappings.finder[%s] -> %s", vim.inspect(key), vim.inspect(command)),

          string.format(
            "Expected a valid finder command, got %s. Valid finder commands: { %s }",
            vim.inspect(command),
            table.concat(valid_finder_commands, ", ")
          )
        )
      end
    end

    if validate_type(config.mappings.finder, "mappings.finder", "table") then
      for key, command in pairs(config.mappings.finder) do
        validate_finder_map(command, key)
      end
    end

    ---Validates a mapping set whose values are command names, `false`, or (optionally) functions
    ---@param set string name of the mapping set, e.g. "status"
    ---@param allow_functions boolean whether a function may be bound instead of a command name
    local function validate_command_map(set, allow_functions)
      local valid_commands = {
        false,
      }

      for _, cmd in pairs(M.get_default_values().mappings[set]) do
        table.insert(valid_commands, cmd)
      end

      local name = "mappings." .. set
      local value_types = allow_functions and { "string", "boolean", "function" } or { "string", "boolean" }

      if validate_type(config.mappings[set], name, "table") then
        for key, command in pairs(config.mappings[set]) do
          if
            validate_type(key, name .. " -> " .. vim.inspect(key), "string")
            and validate_type(command, string.format("%s['%s']", name, key), value_types)
          then
            if type(command) == "string" and not vim.tbl_contains(valid_commands, command) then
              local valid_commands = util.map(valid_commands, function(command)
                return vim.inspect(command)
              end)

              err(
                string.format("%s['%s']", name, key),
                string.format(
                  "Expected a valid %s command, got '%s'. Valid %s commands: { %s }",
                  set,
                  command,
                  set,
                  table.concat(valid_commands, ", ")
                )
              )
            end
          end
        end
      end
    end

    validate_command_map("status", true)
    validate_command_map("popup", false)
    validate_command_map("commit_editor", true)
    validate_command_map("commit_editor_I", true)
    validate_command_map("commit_view", true)
  end

  if validate_type(config, "base config", "table") then
    validate_type(config.disable_hint, "disable_hint", "boolean")
    validate_type(config.disable_context_highlighting, "disable_context_highlighting", "boolean")
    validate_type(config.disable_signs, "disable_signs", "boolean")
    validate_type(config.svn_executable, "svn_executable", "string")
    validate_staging_changelist()
    validate_type(config.telescope_sorter, "telescope_sorter", "function")
    validate_type(config.use_per_project_settings, "use_per_project_settings", "boolean")
    validate_type(config.remember_settings, "remember_settings", "boolean")
    validate_type(config.notification_icon, "notification_icon", "string")
    validate_type(config.console_timeout, "console_timeout", "number")
    validate_type(config.process_spinner, "process_spinner", "boolean")
    validate_kind(config.kind, "kind")
    if validate_type(config.floating, "floating", "table") then
      validate_type(config.floating.relative, "relative", "string")
      validate_type(config.floating.width, "width", "number")
      validate_type(config.floating.height, "height", "number")
      validate_type(config.floating.style, "style", "string")
      validate_type(config.floating.border, "border", "string")
    end
    validate_type(config.disable_line_numbers, "disable_line_numbers", "boolean")
    validate_type(config.disable_relative_line_numbers, "disable_relative_line_numbers", "boolean")
    validate_type(config.auto_show_console, "auto_show_console", "boolean")
    validate_type(config.auto_show_console_on, "auto_show_console_on", "string")
    validate_type(config.auto_close_console, "auto_close_console", "boolean")
    if validate_type(config.filewatcher, "filewatcher", "table") then
      validate_type(config.filewatcher.enabled, "filewatcher.enabled", "boolean")
    end
    if validate_type(config.status, "status", "table") then
      validate_type(config.status.recent_commit_count, "status.recent_commit_count", "number")
      validate_type(config.status.mode_padding, "status.mode_padding", "number")
      validate_type(config.status.HEAD_padding, "status.HEAD_padding", "number")
      validate_type(config.status.HEAD_folded, "status.HEAD_folded", "boolean")
      validate_type(config.status.mode_text, "status.mode_text", "table")
    end
    validate_signs()
    validate_trinary_auto(config.disable_insert_on_commit, "disable_insert_on_commit")
    -- Commit Editor
    if validate_type(config.commit_editor, "commit_editor", "table") then
      validate_type(config.commit_editor.show_staged_diff, "show_staged_diff", "boolean")
      validate_type(config.commit_editor.spell_check, "spell_check", "boolean")
      validate_kind(config.commit_editor.kind, "commit_editor")
    end
    -- Commit Select View
    if validate_type(config.commit_select_view, "commit_select_view", "table") then
      validate_kind(config.commit_select_view.kind, "config.commit_select_view.kind")
    end
    -- Commit (revision) View
    if validate_type(config.commit_view, "commit_view", "table") then
      validate_kind(config.commit_view.kind, "commit_view.kind")
    end
    -- Log View
    if validate_type(config.log_view, "log_view", "table") then
      validate_kind(config.log_view.kind, "log_view.kind")
    end
    -- Preview Buffer
    if validate_type(config.preview_buffer, "preview_buffer", "table") then
      validate_kind(config.preview_buffer.kind, "preview_buffer.kind")
    end
    -- Popup
    if validate_type(config.popup, "popup", "table") then
      validate_kind(config.popup.kind, "popup.kind")
      validate_type(config.popup.show_title, "popup.show_title", "boolean")
    end

    validate_integrations()
    validate_sections()
    validate_ignored_settings()
    validate_mappings()
    validate_highlights()
  end

  return errors
end

---Get the configured svn executable path
---@return string The svn executable path
function M.get_svn_executable()
  return M.values.svn_executable
end

---Name of the changelist that acts as the staging area
---@return string
function M.get_staging_changelist()
  return M.values.staging_changelist
end

---@param name string
---@return boolean
function M.check_integration(name)
  local logger = require("sven.logger")
  local enabled = M.values.integrations[name]

  if enabled == nil or enabled == "auto" then
    local success, _ = pcall(require, name:gsub("_", "-"))
    logger.info(("[CONFIG] Found auto integration '%s = %s'"):format(name, success))
    return success
  end

  logger.info(("[CONFIG] Found explicit integration '%s' = %s"):format(name, enabled))
  return enabled
end

function M.setup(opts)
  if opts == nil then
    return
  end

  -- Mapping lookups are memoized, so they must be rebuilt when the config changes
  mappings = {}

  if opts.use_default_keymaps == false then
    M.values.mappings = {
      status = {},
      popup = {},
      finder = {},
      commit_editor = {},
      commit_editor_I = {},
      commit_view = {},
    }
  else
    -- Clear our any "false" user mappings from defaults
    for section, maps in pairs(opts.mappings or {}) do
      for k, v in pairs(maps) do
        if v == false and M.values.mappings[section] then
          M.values.mappings[section][k] = nil
          opts.mappings[section][k] = nil
        end
      end
    end
  end

  M.values = vim.tbl_deep_extend("force", M.values, opts)

  local config_errs = M.validate_config()
  if vim.tbl_count(config_errs) == 0 then
    return
  end
  local header = "====Sven Configuration Errors===="
  local header_message = {
    "Sven has NOT been setup!",
    "You have a misconfiguration in your Sven setup!",
    'Validate that your configuration passed to `require("sven").setup()` is valid!',
  }
  local header_sep = ""
  for _ = 0, string.len(header), 1 do
    header_sep = header_sep .. "-"
  end

  local config_errs_message = {}
  for config_key, err in pairs(config_errs) do
    table.insert(config_errs_message, string.format("Config value: `%s` had error -> %s", config_key, err))
  end
  error(
    string.format(
      "\n%s\n%s\n%s\n%s",
      header,
      table.concat(header_message, "\n"),
      header_sep,
      table.concat(config_errs_message, "\n")
    ),
    vim.log.levels.ERROR
  )
end

return M
