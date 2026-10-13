local Ui = require("sven.lib.ui")
local Component = require("sven.lib.ui.component")
local util = require("sven.lib.util")
local common = require("sven.buffers.common")
local a = require("sven.lib.async")
local event = require("sven.lib.event")

local col = Ui.col
local row = Ui.row
local text = Ui.text

local map = util.map

local EmptyLine = common.EmptyLine
local List = common.List
local DiffHunks = common.DiffHunks

---Components of the status buffer. A port of Neogit's `buffers/status/ui.lua` onto the state of
---a Subversion working copy (see `sven.lib.svn.repository`).
local M = {}

local HINT = Component.new(function(props)
  ---@return table<string, string[]>
  local function reversed_lookup(tbl)
    local result = {}
    for k, v in pairs(tbl) do
      if v then
        local current = result[v]
        if current then
          table.insert(current, k)
        else
          result[v] = { k }
        end
      end
    end

    return result
  end

  local reversed_status_map = reversed_lookup(props.config.mappings.status)
  local reversed_popup_map = reversed_lookup(props.config.mappings.popup)

  local entry = function(name, hint)
    local keys = reversed_status_map[name] or reversed_popup_map[name]
    local key_hint

    if keys and #keys > 0 then
      table.sort(keys)
      key_hint = table.concat(keys, " ")
    else
      key_hint = "<unmapped>"
    end

    return row {
      text.highlight("SvenPopupActionKey")(key_hint),
      text(" "),
      text(hint),
    }
  end

  return row {
    text.highlight("SvenSubtleText")("Hint: "),
    entry("Toggle", "toggle"),
    text.highlight("SvenSubtleText")(" | "),
    entry("Stage", "stage"),
    text.highlight("SvenSubtleText")(" | "),
    entry("Unstage", "unstage"),
    text.highlight("SvenSubtleText")(" | "),
    entry("Discard", "discard"),
    text.highlight("SvenSubtleText")(" | "),
    entry("CommitPopup", "commit"),
    text.highlight("SvenSubtleText")(" | "),
    entry("HelpPopup", "help"),
  }
end)

-- The counterpart of Neogit's `Head:` row: the revision the working copy is at instead of a
-- commit hash, its location in the repository instead of a branch name.
local HEAD = Component.new(function(props)
  local revision = props.revision and ("r" .. props.revision) or ""

  return row({
    text.highlight("SvenStatusHEAD")(util.pad_right(props.name .. ": ", props.HEAD_padding)),
    text.highlight("SvenRevision")(revision),
    text(revision ~= "" and " " or ""),
    text.highlight("SvenBranch")(props.relative_url or ""),
    text(props.msg and " " or ""),
    text(props.msg or ""),
  }, { yankable = props.yankable })
end)

local Url = Component.new(function(props)
  return row({
    text.highlight("SvenStatusHEAD")(util.pad_right(props.name .. ": ", props.HEAD_padding)),
    text.highlight("SvenUrl")(props.url or ""),
  }, { yankable = props.url })
end)

local SectionTitle = Component.new(function(props)
  return { text.highlight(props.highlight or "SvenSectionHeader")(props.title) }
end)

local SectionTitleChangelist = Component.new(function(props)
  return {
    text.highlight(props.highlight or "SvenSectionHeader")(props.title),
    text(" "),
    text.highlight("SvenChangelistName")(props.changelist),
  }
end)

local Section = Component.new(function(props)
  local count
  if props.count then
    count = { text(" ("), text.highlight("SvenSectionHeaderCount")(#props.items), text(")") }
  end

  return col.tag("Section")({
    row(util.merge(props.title, count or {})),
    col(map(props.items, props.render)),
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    id = props.name,
  })
end)

---What sets an item apart, beyond its mode: shown in parentheses behind its name.
---@param item SvenStatusItem
---@return string[]
local function annotations(item)
  local notes = {}

  if item.conflicted then
    local kinds = {}
    if item.text_conflicted then
      table.insert(kinds, "text")
    end
    if item.prop_conflicted then
      table.insert(kinds, "property")
    end
    if item.tree_conflicted then
      table.insert(kinds, "tree")
    end

    -- A plain text conflict is what "conflicted" says already
    if not (#kinds == 1 and kinds[1] == "text") then
      table.insert(notes, table.concat(kinds, " and ") .. " conflict")
    end
  end

  if item.props == "modified" then
    local text_changed = item.text_status ~= "normal" and item.text_status ~= "none"
    table.insert(notes, text_changed and "+properties" or "properties")
  end

  if item.moved_to then
    table.insert(notes, "moved to " .. item.moved_to)
  elseif item.copied and not item.moved_from then
    table.insert(notes, "copied")
  end

  if item.switched then
    table.insert(notes, "switched")
  end

  if item.locked then
    table.insert(notes, "locked")
  end

  if item.implied then
    table.insert(notes, "needed by staged files")
  end

  return notes
end

---@param status string
---@return string The highlight group of an item with that status
local function change_highlight(status)
  return "SvenChange" .. status:sub(1, 1):upper() .. status:sub(2)
end

---@param item SvenStatusItem
---@return string The path as it is shown: directories end in a slash
function M.display_name(item)
  if item.kind == "dir" and item.name ~= "." then
    return item.name .. "/"
  end

  return item.name
end

local SectionItemFile = function(section, config)
  return Component.new(function(item)
    local load_diff = function(item)
      ---@param this Component
      ---@param ui Ui
      ---@param prefix string|nil
      return a.void(function(this, ui, prefix)
        this.options.on_open = nil
        this.options.folded = false

        local row, _ = this:row_range_abs()
        row = row + 1 -- Filename row

        local diff = item.diff

        -- Binary notice and property changes sit between the file name and the hunks
        row = row + #diff.info

        for _, hunk in ipairs(diff.hunks) do
          hunk.first = row
          hunk.last = row + hunk.length
          row = hunk.last + 1

          -- Set fold state when called from ui:update()
          if prefix then
            local key = ("%s--%s"):format(prefix, hunk.hash)
            if ui._node_fold_state and ui._node_fold_state[key] then
              hunk._folded = ui._node_fold_state[key].folded
            end
          end
        end

        ui.buf:with_locked_viewport(function()
          this:append(DiffHunks(diff))
          ui:update()
        end)

        event.send("DiffLoaded", {
          item = {
            absolute_path = item.absolute_path,
            relative_path = item.escaped_path,
            row_start = item.first,
            row_end = item.last,
            mode = item.mode,
          },
          diff = {
            kind = diff.kind,
            lines = diff.lines,
            hunks = util.map(diff.hunks, function(hunk)
              local original_lines = util.filter_map(hunk.lines, function(line)
                if not (vim.startswith(line, "+") or vim.startswith(line, "-")) then
                  return line
                end
              end)

              local modified_lines = util.map(hunk.lines, function(line)
                return line:gsub("^[+-]", " ")
              end)

              return {
                lines = hunk.lines,
                original_lines = original_lines,
                modified_lines = modified_lines,
                row_start = hunk.first,
                row_end = hunk.last,
                header = hunk.line,
              }
            end),
          },
        })
      end)
    end

    local mode = config.status.mode_text[item.mode] or item.status
    local mode_text
    if mode == "" then
      mode_text = ""
    elseif config.status.mode_padding > 0 then
      mode_text = util.pad_right(
        mode,
        util.max_length(vim.tbl_values(config.status.mode_text)) + config.status.mode_padding
      )
    else
      mode_text = mode .. " "
    end

    local name = M.display_name(item)
    if item.moved_from then
      name = ("%s -> %s"):format(item.moved_from, name)
    end

    local notes = annotations(item)
    local note = #notes > 0 and (" (%s)"):format(table.concat(notes, ", ")) or ""

    return col.tag("Item")({
      row {
        text.highlight(change_highlight(item.status))(mode_text),
        text(name),
        text.highlight("SvenSubtleText")(note),
      },
    }, {
      foldable = true,
      folded = true,
      on_open = load_diff(item),
      context = true,
      id = ("%s--%s"):format(section, item.name),
      yankable = item.name,
      filename = item.name,
      item = item,
    })
  end)
end

---@class SvenStatusCommitItem What the status buffer lists under "Recent commits"
---@field name string
---@field oid string The revision number, as a string
---@field commit SvenLogEntry

---@param entry SvenLogEntry
---@return SvenStatusCommitItem
local function present_commit(entry)
  return {
    name = ("%s %s"):format(entry.abbreviated_commit, entry.subject or ""),
    oid = entry.oid,
    commit = entry,
  }
end

local SectionItemCommit = function(config)
  return Component.new(function(item)
    local commit = item.commit

    local rel_date = commit.rel_date or ""
    if rel_date:match(" years?,") then
      rel_date = rel_date:gsub(" years?,", "y") .. " "
    elseif rel_date:match("^%d ") then
      rel_date = " " .. rel_date
    end

    local date = config.log_date_format == nil and rel_date or commit.log_date or ""

    return row({
      text.highlight("SvenObjectId")(commit.abbreviated_commit),
      text(" "),
      text(commit.subject or ""),
    }, {
      virtual_text = {
        { " ", "Constant" },
        {
          util.str_clamp(commit.author_name or "", 30 - (#date > 10 and #date or 10)),
          "SvenGraphAuthor",
        },
        { util.str_min_width(date, 10), "Special" },
      },
      oid = commit.oid,
      yankable = commit.abbreviated_commit,
      item = item,
    })
  end)
end

---The log entry the working copy is at: the newest one that is not newer than its revision.
---@param state SvenRepoState
---@return SvenLogEntry|nil
local function head_commit(state)
  local revision = state.info and state.info.revision
  if not revision then
    return nil
  end

  for _, entry in ipairs(state.recent.items) do
    if entry.revision <= revision then
      return entry
    end
  end
end

---@param state SvenRepoState
---@param config SvenConfig
---@return table[]
function M.Status(state, config)
  local info = state.info or {}

  ---@param name string Key into `config.sections`
  ---@return SvenConfigSection
  local function section_config(name)
    return config.sections[name] or { folded = false, hidden = false }
  end

  ---@param name string Key into `config.sections`
  ---@param items table[]
  ---@return boolean
  local function show(name, items)
    return #items > 0 and not section_config(name).hidden
  end

  local head = head_commit(state)
  local show_hint = not config.disable_hint

  local items = {}
  local function add(component)
    if component then
      table.insert(items, component)
    end
  end

  add(show_hint and HINT { config = config })
  add(show_hint and EmptyLine())

  add(col.tag("Section")({
    HEAD {
      name = "Head",
      revision = info.revision,
      relative_url = info.relative_url,
      msg = head and head.subject,
      yankable = info.revision and ("r" .. info.revision) or nil,
      HEAD_padding = config.status.HEAD_padding,
    },
    info.url and Url {
      name = "URL",
      url = info.url,
      HEAD_padding = config.status.HEAD_padding,
    },
  }, { foldable = true, folded = config.status.HEAD_folded }))
  add(EmptyLine())

  add(show("conflicts", state.conflicts.items) and Section {
    title = SectionTitle { title = "Conflicts", highlight = "SvenConflicts" },
    count = true,
    render = SectionItemFile("conflicts", config),
    items = state.conflicts.items,
    folded = section_config("conflicts").folded,
    name = "conflicts",
  })

  add(show("unversioned", state.unversioned.items) and Section {
    title = SectionTitle { title = "Unversioned files", highlight = "SvenUnversionedfiles" },
    count = true,
    render = SectionItemFile("unversioned", config),
    items = state.unversioned.items,
    folded = section_config("unversioned").folded,
    name = "unversioned",
  })

  add(show("changes", state.changes.items) and Section {
    title = SectionTitle { title = "Changes", highlight = "SvenChanges" },
    count = true,
    render = SectionItemFile("changes", config),
    items = state.changes.items,
    folded = section_config("changes").folded,
    name = "changes",
  })

  for _, changelist in ipairs(state.changelists) do
    local name = "changelist:" .. changelist.name

    add(show("changelists", changelist.items) and Section {
      title = SectionTitleChangelist {
        title = "Changelist",
        changelist = changelist.name,
        highlight = "SvenChangelist",
      },
      count = true,
      render = SectionItemFile(name, config),
      items = changelist.items,
      folded = section_config("changelists").folded,
      name = name,
    })
  end

  add(show("staged", state.staged.items) and Section {
    title = SectionTitle { title = "Staged changes", highlight = "SvenStagedchanges" },
    count = true,
    render = SectionItemFile("staged", config),
    items = state.staged.items,
    folded = section_config("staged").folded,
    name = "staged",
  })

  add(show("recent", state.recent.items) and Section {
    title = SectionTitle { title = "Recent commits", highlight = "SvenRecentcommits" },
    count = false,
    render = SectionItemCommit(config),
    items = map(state.recent.items, present_commit),
    folded = section_config("recent").folded,
    name = "recent",
  })

  return {
    List {
      items = items,
    },
  }
end

return M
