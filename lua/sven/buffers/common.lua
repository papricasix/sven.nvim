local Ui = require("sven.lib.ui")
local Component = require("sven.lib.ui.component")
local util = require("sven.lib.util")
local config = require("sven.config")

local text = Ui.text
local col = Ui.col
local row = Ui.row
local map = util.map
local flat_map = util.flat_map
local filter = util.filter
local intersperse = util.intersperse

local M = {}

M.EmptyLine = Component.new(function()
  return col { row { text("") } }
end)

---@param diff Diff
M.Diff = Component.new(function(diff)
  return col.tag("Diff")({
    text(string.format("%s %s", diff.kind, diff.file), { line_hl = "SvenDiffHeader" }),
    M.DiffHunks(diff),
  }, { foldable = true, folded = false, context = true, diff = diff })
end)

---@param diff Diff
M.DiffHunks = Component.new(function(diff)
  local hunk_props = {}
  for i, hunk in ipairs(diff.hunks) do
    table.insert(hunk_props, {
      header = diff.lines[hunk.diff_from],
      content = diff.pager_contents[i],
      hunk = hunk,
      folded = hunk._folded,
      filepath = diff.file,
    })
  end

  return col.tag("DiffContent") {
    col.tag("DiffInfo")(map(diff.info, text)),
    col.tag("HunkList")(map(hunk_props, M.Hunk)),
  }
end)

local HunkLine = Component.new(function(line, hunk)
  local line_hl

  -- Dynamically compute prefix length from the hunk header (defaulting to 1)
  local prefix_length = 1
  if hunk and hunk.line then
    local at_signs = string.match(hunk.line, "^(@+)")
    if at_signs then
      prefix_length = #at_signs - 1
    end
  end

  -- Isolate the exact status prefix for this specific line
  local prefix = string.sub(line, 1, prefix_length)

  -- Evaluate Highlighting
  if
    line:match("^..<<<<<<<")
    or line:match("^..|||||||")
    or line:match("^..=======")
    or line:match("^..>>>>>>>")
  then
    line_hl = "SvenHunkMergeHeader"

  -- If the prefix contains a '+', it's an addition (e.g., "+", " +", "+ ")
  elseif string.match(prefix, "%+") then
    line_hl = "SvenDiffAdd"

  -- If the prefix contains a '-', it's a deletion (e.g., "-", " -", "- ")
  elseif string.match(prefix, "%-") then
    line_hl = "SvenDiffDelete"

  -- If it contains neither (just spaces), it is unchanged context
  else
    line_hl = "SvenDiffContext"
  end

  return text(line, { line_hl = line_hl })
end)

M.Hunk = Component.new(function(props)
  return col.tag("Hunk")({
    text.line_hl("SvenHunkHeader")(props.header),
    col.tag("HunkContent")(map(props.content, function(line)
      return HunkLine(line, props.hunk)
    end)),
  }, {
    ansi_hl = config.values.log_pager ~= nil,
    foldable = true,
    folded = props.folded or false,
    context = true,
    hunk = props.hunk,
    filepath = props.filepath,
  })
end)

M.List = Component.new(function(props)
  local children = filter(props.items, function(x)
    return type(x) == "table"
  end)

  if props.separator then
    children = intersperse(children, text(props.separator))
  end

  local container = col

  if props.horizontal then
    container = row
  end

  return container.tag("List")(children)
end)

---@return Component[]
local function build_graph(graph, opts)
  opts = opts or { remove_dots = false }

  if type(graph) == "table" then
    return util.map(graph, function(g)
      local char = g.text
      if opts.remove_dots and vim.tbl_contains({ "", "", "", "", "•" }, char) then
        char = ""
      end

      return text(char, { highlight = string.format("SvenGraph%s", g.color) })
    end)
  else
    return { text(graph, { highlight = "Include" }) }
  end
end

---Renders one log entry as a row, optionally with a foldable details block.
---
---Subversion has no refs, so unlike Neogit nothing is decorated. `commit` is a `SvenLogEntry`
---(see `sven.lib.svn.log`), which carries the Neogit-style fields this component reads:
---`oid`, `abbreviated_commit`, `subject`, `body`, `author_name`, `author_email`, `author_date`,
---`committer_*`, `rel_date`, `log_date` and optionally `graph`.
---@param commit SvenLogEntry
---@param _remotes any Unused. Kept so that call sites ported from Neogit keep their shape.
---@param args { details: boolean?, graph: boolean? }
M.CommitEntry = Component.new(function(commit, _remotes, args)
  args = args or {}

  if commit.rel_date:match(" years?,") then
    commit.rel_date, _ = commit.rel_date:gsub(" years?,", "y")
    commit.rel_date = commit.rel_date .. " "
  elseif commit.rel_date:match("^%d ") then
    commit.rel_date = " " .. commit.rel_date
  end

  local details
  if args.details then
    local graph = args.graph and build_graph(commit.graph, { remove_dots = true }) or { text("") }
    details = col.padding_left(#commit.abbreviated_commit + 1) {
      row(util.merge(graph, {
        text(" "),
        text("Author:     ", { highlight = "SvenSubtleText" }),
        text(commit.author_name, { highlight = "SvenGraphAuthor" }),
        text(" <"),
        text(commit.author_email),
        text(">"),
      })),
      row(util.merge(graph, {
        text(" "),
        text("AuthorDate: ", { highlight = "SvenSubtleText" }),
        text(commit.author_date),
      })),
      row(util.merge(graph, {
        text(" "),
        text("Commit:     ", { highlight = "SvenSubtleText" }),
        text(commit.committer_name),
        text(" <"),
        text(commit.committer_email),
        text(">"),
      })),
      row(util.merge(graph, {
        text(" "),
        text("CommitDate: ", { highlight = "SvenSubtleText" }),
        text(commit.committer_date),
      })),
      row(graph),
      col(
        flat_map({ commit.subject, commit.body }, function(line)
          local lines = vim.split(line, "\n")

          -- TODO: More correctly handle newlines/wrapping in messages
          -- lines = util.flat_map(lines, function(line)
          --   return util.str_wrap(line, vim.o.columns * 0.6)
          -- end)

          lines = map(lines, function(l)
            return row(util.merge(graph, { text(" "), text(l) }))
          end)

          if #lines > 2 then
            return util.merge({ row(graph) }, lines, { row(graph) })
          elseif #lines > 1 then
            return util.merge({ row(graph) }, lines)
          else
            return lines
          end
        end),
        { highlight = "SvenCommitViewDescription" }
      ),
    }
  end

  local date = (config.values.log_date_format == nil and commit.rel_date or commit.log_date)
  local graph = args.graph and build_graph(commit.graph) or { text("") }

  return col.tag("commit")({
    row(
      util.merge({
        text(commit.abbreviated_commit, { highlight = "SvenObjectId" }),
        text(" "),
      }, graph, { text(" ") }, { text(commit.subject) }),
      {
        virtual_text = {
          { " ", "Constant" },
          {
            util.str_clamp(commit.author_name, 30 - (#date > 10 and #date or 10)),
            "SvenGraphAuthor",
          },
          { util.str_min_width(date, 10), "Special" },
        },
      }
    ),
    details,
  }, {
    item = commit,
    oid = commit.oid,
    foldable = args.details == true,
    folded = true,
  })
end)

M.CommitGraph = Component.new(function(commit, padding)
  return col.tag("graph").padding_left(padding) { row(build_graph(commit.graph)) }
end)

M.Grid = Component.new(function(props)
  props = vim.tbl_extend("force", {
    -- Gap between columns
    gap = 0,
    columns = true, -- whether the items represents a list of columns instead of a list of row
    items = {},
  }, props)

  --- Transpose
  if props.columns then
    local new_items = {}
    local row_count = 0
    for i = 1, #props.items do
      local l = #props.items[i]

      if l > row_count then
        row_count = l
      end
    end
    for _ = 1, row_count do
      table.insert(new_items, {})
    end
    for i = 1, #props.items do
      for j = 1, row_count do
        local x = props.items[i][j] or text("")
        table.insert(new_items[j], x)
      end
    end
    props.items = new_items
  end

  local rendered = {}
  local column_widths = {}

  for i = 1, #props.items do
    local children = {}

    local r = props.items[i]

    for j = 1, #r do
      local item = r[j]
      local c = props.render_item(item)

      if c.tag ~= "text" and c.tag ~= "row" then
        error("Grid component only supports text and row components for now")
      end

      local c_width = c:get_width()
      children[j] = c

      -- Compute the maximum element width of each column to pad all columns to the same vertical line
      if c_width > (column_widths[j] or 0) then
        column_widths[j] = c_width
      end
    end

    rendered[i] = row(children)
  end

  for i = 1, #rendered do
    -- current row
    local r = rendered[i]

    -- Draw each column of the current row
    for j = 1, #r.children do
      local item = r.children[j]
      local gap_str = ""
      local column_width = column_widths[j] or 0

      -- Intersperse each column item with a gap
      if j ~= 1 then
        gap_str = string.rep(" ", props.gap)
      end

      if item.tag == "text" then
        item.value = gap_str .. string.format("%" .. column_width .. "s", item.value)
      elseif item.tag == "row" then
        table.insert(item.children, 1, text(gap_str))
        local width = item:get_width()
        local remaining_width = column_width - width + props.gap
        table.insert(item.children, text(string.rep(" ", remaining_width)))
      else
        error("TODO")
      end
    end
  end

  return col(rendered)
end)

return M
