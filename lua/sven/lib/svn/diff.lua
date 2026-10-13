local a = require("sven.lib.async")
local svn = require("sven.lib.svn")
local config = require("sven.config")
local logger = require("sven.logger")

local insert = table.insert
local sha256 = vim.fn.sha256

---`svn diff`, parsed into the structure Neogit's `lib/git/diff.lua` produces, so that the `Diff`
---and `Hunk` components of `sven.buffers.common` render it unchanged.
---@class SvenDiff
local M = {}

---@class Diff
---@field kind string "modified"|"added"|"deleted" (plus "unversioned"|"missing" for diffs synthesized for status items)
---@field file string Path as printed by svn: relative to the directory svn ran in (the working copy root)
---@field lines string[] All hunks, starting with the first `@@` line. `hunk.diff_from`/`diff_to` index into this
---@field header string[] The lines before the first hunk: `Index:`, the separator, `---` and `+++`
---@field info string[] Lines to show below the file header: binary notice and property changes
---@field stats DiffStats
---@field hunks Hunk[]
---@field pager_contents string[][] Per hunk, its lines piped through `config.log_pager` (the plain lines without a pager)
---@field binary boolean svn refused to show the content (`svn:mime-type` is not a text type)
---@field props SvenPropChange[] Property changes
---@field props_only boolean There are property changes but no text changes
---@field old_label string|nil What is on the left side: "revision 3", "nonexistent", ...
---@field new_label string|nil What is on the right side: "working copy", "revision 4", "nonexistent", ...

---@class DiffStats
---@field additions number
---@field deletions number

---@class Hunk
---@field file string Same as `diff.file`
---@field index_from number First line of the hunk in the old file
---@field index_len number Number of lines of the hunk in the old file
---@field disk_from number First line of the hunk in the new file
---@field disk_len number Number of lines of the hunk in the new file
---@field line string The hunk header (`@@ -1,5 +1,5 @@`)
---@field diff_from number Index of the hunk header in `diff.lines`
---@field diff_to number Index of the last line of the hunk in `diff.lines`
---@field length number Number of lines in the hunk, without the header
---@field hash string Hash of the hunk content. Stable across refreshes while the hunk does not change
---@field lines string[] The lines of the hunk, without the header. Carriage returns of CRLF files are removed
---@field raw string[]|nil The lines exactly as svn printed them. Only set when they differ from `lines` (CRLF files)
---@field first number First line number in buffer (set by the UI)
---@field last number Last line number in buffer (set by the UI)

---@class SvenPropChange
---@field name string Property name, e.g. `svn:eol-style`
---@field action string "Added"|"Deleted"|"Modified"
---@field lines string[] The property hunk(s) as printed by svn, starting with the `## -0,0 +1 ##` line

---@class SvenDiffResult
---@field raw string The complete output of svn
---@field lines string[] The complete output of svn, by line
---@field diffs Diff[] One entry per changed path, in the order svn printed them
---@field stats DiffStats Totals over all diffs

---@param content string[]
---@return string
local function hunk_hash(content)
  return sha256(table.concat(content, "\n"))
end

---@param lines string[] The hunks of one file, starting at the first hunk header
---@return Hunk[]
local function build_hunks(lines)
  local hunks = {}
  local hunk = nil
  local hunk_content = {}

  for i = 1, #lines do
    local line = lines[i]
    local index_from, index_len, disk_from, disk_len = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

    if index_from then
      if hunk ~= nil then
        hunk.hash = hunk_hash(hunk_content)
        hunk_content = {}
        insert(hunks, hunk)
      end

      hunk = {
        index_from = tonumber(index_from),
        index_len = tonumber(index_len) or 1,
        disk_from = tonumber(disk_from),
        disk_len = tonumber(disk_len) or 1,
        line = line,
        diff_from = i,
        diff_to = i,
      }
    else
      insert(hunk_content, line)

      if hunk then
        hunk.diff_to = hunk.diff_to + 1
      end
    end
  end

  if hunk then
    hunk.hash = hunk_hash(hunk_content)
    insert(hunks, hunk)
  end

  for _, hunk in ipairs(hunks) do
    hunk.lines = {}
    for i = hunk.diff_from + 1, hunk.diff_to do
      insert(hunk.lines, lines[i])
    end

    hunk.length = hunk.diff_to - hunk.diff_from
  end

  return hunks
end

---@param diff_header string[]
---@param lines string[]
---@param hunks Hunk[]
---@return string[][]
local function build_pager_contents(diff_header, lines, hunks)
  local res = {}
  local jobs = {}
  vim.iter(hunks):each(function(hunk)
    local header = lines[hunk.diff_from]
    local content = vim.list_slice(lines, hunk.diff_from + 1, hunk.diff_to)
    if config.values.log_pager == nil then
      insert(res, content)
      return
    end

    local job = vim.system(config.values.log_pager, { stdin = true })
    for _, part in ipairs { diff_header, { header }, content } do
      for _, line in ipairs(part) do
        job:write(line .. "\n")
      end
    end
    job:write()
    insert(jobs, job)
  end)

  if config.values.log_pager ~= nil then
    vim.iter(jobs):each(function(job)
      local content = vim.split(job:wait().stdout, "\n")
      insert(res, content)
    end)
  end

  return res
end

---@param hunks Hunk[]
---@return DiffStats
local function build_stats(hunks)
  local stats = { additions = 0, deletions = 0 }
  for _, hunk in ipairs(hunks) do
    for _, line in ipairs(hunk.lines) do
      local operand = line:sub(1, 1)
      if operand == "+" then
        stats.additions = stats.additions + 1
      elseif operand == "-" then
        stats.deletions = stats.deletions + 1
      end
    end
  end

  return stats
end

---Parses the `Property changes on:` section of a file
---@param lines string[] The section, starting at the `Property changes on:` line
---@return SvenPropChange[]
local function build_props(lines)
  local props = {}
  local current

  for _, line in ipairs(lines) do
    local action, name = line:match("^(%u%l+): (.+)$")
    if action == "Added" or action == "Deleted" or action == "Modified" then
      current = { name = name, action = action, lines = {} }
      insert(props, current)
    elseif current and line ~= "" then
      insert(current.lines, line)
    end
  end

  return props
end

---@param header string[]
---@param prefix string "---" or "+++"
---@return string|nil label The text in the trailing parentheses: "revision 3", "working copy", "nonexistent"
local function header_label(header, prefix)
  for _, line in ipairs(header) do
    if vim.startswith(line, prefix .. " ") then
      return line:match("\t%((.-)%)$")
    end
  end
end

---@param old_label string|nil
---@param new_label string|nil
---@param hunks Hunk[]
---@return string
local function build_kind(old_label, new_label, hunks)
  local first = hunks[1]

  if old_label == "nonexistent" or old_label == "revision 0" then
    return "added"
  elseif new_label == "nonexistent" then
    return "deleted"
  elseif #hunks == 1 and first.index_from == 0 and first.index_len == 0 then
    -- Labels are missing or translated. A file that had no lines before was added.
    return old_label == nil and "added" or "modified"
  end

  return "modified"
end

---@param line string
---@return string
local function strip_cr(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end

  return line
end

---@class SvenRawFileDiff
---@field file string
---@field header string[]
---@field body string[]
---@field prop_lines string[]

---Builds the diff of one file from its sections
---@param section SvenRawFileDiff
---@return Diff
local function build_diff(section)
  -- Carriage returns of CRLF files are noise on screen, but needed to build patches
  local has_cr = false
  local lines = {}
  for i, line in ipairs(section.body) do
    lines[i] = strip_cr(line)
    has_cr = has_cr or lines[i] ~= line
  end

  local hunks = build_hunks(lines)
  for _, hunk in ipairs(hunks) do
    hunk.file = section.file
    if has_cr then
      hunk.raw = vim.list_slice(section.body, hunk.diff_from + 1, hunk.diff_to)
    end
  end

  local header = {}
  local info = {}
  local binary = false
  for i, line in ipairs(section.header) do
    if i <= 2 or line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
      insert(header, line)
    elseif line ~= "" then
      -- "Cannot display: file marked as a binary type." and the mime type below it
      binary = binary or line:match("^Cannot display") ~= nil
      insert(info, line)
    end
  end

  local props = build_props(section.prop_lines)
  for _, prop in ipairs(props) do
    insert(info, ("%s: %s"):format(prop.action, prop.name))
    for _, line in ipairs(prop.lines) do
      insert(info, line)
    end
  end

  local old_label = header_label(header, "---")
  local new_label = header_label(header, "+++")

  return { ---@type Diff
    kind = build_kind(old_label, new_label, hunks),
    file = section.file,
    lines = lines,
    header = header,
    info = info,
    stats = build_stats(hunks),
    hunks = hunks,
    pager_contents = build_pager_contents(header, lines, hunks),
    binary = binary,
    props = props,
    props_only = #props > 0 and #hunks == 0 and not binary,
    old_label = old_label,
    new_label = new_label,
  }
end

---Parses the output of `svn diff`.
---
---Every changed path starts with an `Index: <path>` line followed by a line of `=`. Then come
---the `---`/`+++` lines and the hunks (or a note that the file is binary), optionally followed
---by a `Property changes on: <path>` section.
---@param raw string[]|string Output of `svn diff`, as lines or as one string
---@return Diff[]
function M.parse(raw)
  local output = type(raw) == "string" and vim.split(raw, "\n", { plain = true }) or raw --[[@as string[] ]]

  local sections = {}
  local current ---@type SvenRawFileDiff|nil
  local mode = "header"

  local function start(file)
    current = { file = file, header = {}, body = {}, prop_lines = {} }
    insert(sections, current)
    mode = "header"
  end

  for i, line in ipairs(output) do
    local next_line = output[i + 1]
    local index = line:match("^Index: (.+)$")

    if index and next_line and next_line:match("^=+\r?$") then
      start(strip_cr(index))
      insert(current.header, strip_cr(line))
    elseif line:match("^Property changes on: ") and mode ~= "props" then
      local path = strip_cr(line:match("^Property changes on: (.+)$"))
      if not current or current.file ~= path then
        -- Property changes without a preceding Index block
        start(path)
      end

      mode = "props"
      insert(current.prop_lines, strip_cr(line))
    elseif current then
      if mode == "header" then
        if line:match("^@@ ") then
          mode = "hunks"
          insert(current.body, line)
        else
          insert(current.header, strip_cr(line))
        end
      elseif mode == "hunks" then
        -- Content lines always carry a prefix. An empty line only separates the hunks from what follows.
        if line ~= "" then
          insert(current.body, line)
        end
      else
        insert(current.prop_lines, strip_cr(line))
      end
    end
  end

  return vim.tbl_map(build_diff, sections)
end

---@param diffs Diff[]
---@return DiffStats
local function total_stats(diffs)
  local stats = { additions = 0, deletions = 0 }
  for _, diff in ipairs(diffs) do
    stats.additions = stats.additions + diff.stats.additions
    stats.deletions = stats.deletions + diff.stats.deletions
  end

  return stats
end

---@class SvenDiffOpts: SvenCliOpts
---@field paths? string[] Limit the diff to these paths (relative to the working copy root, or absolute) or URLs
---@field change? string|number `-c`: the change made by this revision
---@field revision? string `-r`: a revision or range, e.g. "5", "3:5", "BASE:HEAD", "PREV:COMMITTED"
---@field depth? string "empty"|"files"|"immediates"|"infinity"
---@field changelist? string Only members of this changelist
---@field args? string[] Additional arguments, e.g. `{ "--ignore-properties", "-x", "-w" }`

---Runs `svn diff` and parses its output.
---
---  svn.diff.run { paths = { "src" } }                 -- local changes below src/
---  svn.diff.run { change = 42, paths = { "^/" } }     -- everything revision 42 changed (network)
---  svn.diff.run { revision = "40:42", paths = { "src/main.c" } }
---
---Diffs against the working copy base need no network access, `change` and `revision` do.
---@param opts SvenDiffOpts|nil
---@return SvenDiffResult
function M.run(opts)
  opts = opts or {}

  local args = { "diff" }
  if opts.change then
    vim.list_extend(args, { "-c", tostring(opts.change) })
  end
  if opts.revision then
    vim.list_extend(args, { "-r", tostring(opts.revision) })
  end
  if opts.depth then
    vim.list_extend(args, { "--depth", opts.depth })
  end
  if opts.changelist then
    vim.list_extend(args, { "--changelist", opts.changelist })
  end
  vim.list_extend(args, opts.args or {})

  local remote = opts.change ~= nil or opts.revision ~= nil

  -- A quirk of svn: when it diffs the working copy against its base it takes the paths as they
  -- are, and an escaping `@` at the end makes it look for a file of that name. In every other
  -- mode it parses a peg revision off the path, like all other subcommands do.
  local pegged = opts.change ~= nil or (opts.revision ~= nil and tostring(opts.revision):upper() ~= "BASE")

  local result = svn.cli.run(
    args,
    svn.cli.opts(opts, {
      hidden = true,
      long = remote,
      raw = true,
      paths = opts.paths,
      verbatim_paths = not pegged,
    })
  )

  local lines = result.stdout
  local diffs = M.parse(lines)

  return {
    raw = table.concat(lines, "\n"),
    lines = lines,
    diffs = diffs,
    stats = total_stats(diffs),
  }
end

---Local modifications: the working copy against its base. Needs no network access.
---@param paths string[]|nil Paths relative to the working copy root. Defaults to the whole working copy
---@param opts SvenDiffOpts|nil
---@return SvenDiffResult
function M.working(paths, opts)
  return M.run(vim.tbl_extend("force", opts or {}, { paths = paths }))
end

---The changes of the staged files: members of the staging changelist. Needs no network access.
---@param opts SvenDiffOpts|nil
---@return SvenDiffResult
function M.staged(opts)
  return M.run(vim.tbl_extend("force", opts or {}, { changelist = config.get_staging_changelist() }))
end

---The change one revision made (`svn diff -c REV`). Contacts the repository.
---@param revision string|number
---@param paths string[]|nil Paths or URLs to limit the diff to. Defaults to the working copy root; pass `{ "^/" }` for the whole repository
---@param opts SvenDiffOpts|nil
---@return SvenDiffResult
function M.revision(revision, paths, opts)
  return M.run(vim.tbl_extend("force", opts or {}, { change = revision, paths = paths }))
end

---The difference between two revisions (`svn diff -r FROM:TO`). Contacts the repository.
---@param from string|number
---@param to string|number|nil Defaults to the working copy
---@param paths string[]|nil Paths or URLs to limit the diff to
---@param opts SvenDiffOpts|nil
---@return SvenDiffResult
function M.range(from, to, paths, opts)
  local revision = to and ("%s:%s"):format(from, to) or tostring(from)
  return M.run(vim.tbl_extend("force", opts or {}, { revision = revision, paths = paths }))
end

---@param kind string
---@param file string
---@return Diff
local function empty_diff(kind, file)
  return {
    kind = kind,
    file = file,
    lines = {},
    header = {},
    info = {},
    stats = { additions = 0, deletions = 0 },
    hunks = {},
    pager_contents = {},
    binary = false,
    props = {},
    props_only = false,
  }
end

-- Unversioned files larger than this are not turned into a diff
local MAX_SYNTHESIZED_BYTES = 1024 * 1024

---Builds the diff of a file that svn cannot diff: all lines added (unversioned) or all lines
---removed (missing).
---@param kind string "unversioned"|"missing"
---@param file string
---@param content string|nil
---@param operand string "+" or "-"
---@return Diff
local function synthesize(kind, file, content, operand)
  local diff = empty_diff(kind, file)

  if not content or content == "" then
    return diff
  end

  if #content > MAX_SYNTHESIZED_BYTES then
    diff.info = { ("File is too large to show (%d bytes)"):format(#content) }
    return diff
  end

  if content:find("\0", 1, true) then
    diff.binary = true
    diff.info = { "Cannot display: file looks like a binary." }
    return diff
  end

  local content_lines = vim.split(content, "\n", { plain = true })
  local no_eol = content_lines[#content_lines] ~= ""
  if not no_eol then
    table.remove(content_lines)
  end

  local count = #content_lines
  local range = count == 1 and "1" or ("1," .. count)
  local header
  if operand == "+" then
    header = ("@@ -0,0 +%s @@"):format(range)
    diff.header = {
      "Index: " .. file,
      string.rep("=", 67),
      ("--- %s\t(nonexistent)"):format(file),
      ("+++ %s\t(working copy)"):format(file),
    }
  else
    header = ("@@ -%s +0,0 @@"):format(range)
    diff.header = {
      "Index: " .. file,
      string.rep("=", 67),
      ("--- %s\t(revision BASE)"):format(file),
      ("+++ %s\t(nonexistent)"):format(file),
    }
  end

  local body = { header }
  for _, line in ipairs(content_lines) do
    insert(body, operand .. line)
  end
  if no_eol then
    insert(body, "\\ No newline at end of file")
  end

  local built = build_diff { file = file, header = diff.header, body = body, prop_lines = {} }
  built.kind = kind

  return built
end

---@param path string
---@return string|nil
local function read_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  if stat.size > MAX_SYNTHESIZED_BYTES then
    -- Enough to trigger the "too large" notice without reading the file
    return string.rep(" ", MAX_SYNTHESIZED_BYTES + 1)
  end

  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local content = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)

  return content
end

---Computes the diff of a status item. Runs svn for versioned items, so it follows the calling
---convention of `sven.lib.svn.cli`. Prefer reading `item.diff`, which caches the result.
---@param item SvenStatusItem
---@return Diff
function M.for_item(item)
  if item.status == "unversioned" or item.status == "ignored" then
    if item.kind == "dir" then
      return empty_diff("unversioned", item.name)
    end

    return synthesize("unversioned", item.name, read_file(item.absolute_path), "+")
  end

  if item.status == "missing" then
    if item.kind == "dir" then
      return empty_diff("missing", item.name)
    end

    local content = svn.cat.file(item.name, "BASE", { hidden = true, ignore_error = true })
    return synthesize("missing", item.name, content, "-")
  end

  local is_dir = item.kind == "dir"

  -- svn would print the complete content of everything below a deleted directory
  if is_dir and item.status == "deleted" then
    return empty_diff(item.status, item.name)
  end

  -- A directory only has property changes of its own. The depth keeps the diffs of what is below
  -- it out.
  local result = M.run {
    paths = { item.name },
    depth = is_dir and "empty" or nil,
    hidden = true,
    ignore_error = true,
  }

  local diff = not is_dir and result.diffs[1] or nil
  for _, candidate in ipairs(result.diffs) do
    if candidate.file == item.name then
      diff = candidate
      break
    end
  end

  if not diff then
    return empty_diff(item.status, item.name)
  end

  -- svn status knows better than the labels of the diff what happened to the item
  if item.status == "added" or item.status == "deleted" or item.status == "replaced" then
    diff.kind = item.status
  end

  return diff
end

-- Loading a diff blocks the editor. Local diffs are quick, this only guards against a hanging svn.
local LOAD_TIMEOUT = 15000

---Makes `item.diff` load lazily: the diff is computed the first time the field is read and
---cached on the item afterwards. Reading it blocks until svn has answered.
---@param item SvenStatusItem
function M.build(item)
  setmetatable(item, {
    __index = function(self, method)
      if method == "diff" then
        logger.debug("[DIFF] Loading diff for: " .. self.name)
        local diff = a.util.block_on(function()
          return M.for_item(self)
        end, LOAD_TIMEOUT)

        rawset(self, "diff", diff)
        return diff
      end
    end,
  })
end

---Builds a patch for a single hunk, or for some of its lines. Ported from Neogit's
---`git.index.generate_patch`.
---
---The patch describes the change from the base to the working file, as svn printed it. Applying
---it in reverse (see `sven.lib.svn.revert`) removes the change from the working file.
---@param hunk Hunk A hunk of a diff of the working copy
---@param opts { from: number?, to: number?, reverse: boolean? }|nil `from`/`to` select lines of the hunk (1-based offsets into `hunk.lines`); `reverse` must be true when the patch is going to be applied in reverse
---@return string patch
function M.generate_patch(hunk, opts)
  opts = opts or {}

  local reverse = opts.reverse or false
  local source = hunk.raw or hunk.lines

  local from = opts.from or 1
  local to = opts.to or #source

  assert(from <= to, string.format("from must be less than or equal to to %d %d", from, to))
  assert(hunk.file, "hunk has no filepath")

  local diff_content = {}
  local len_start = hunk.index_len
  local len_offset = 0

  -- A "\ No newline at end of file" marker belongs to the line before it, and must be dropped
  -- together with that line.
  local previous_kept = true

  for k, line in ipairs(source) do
    local operand = line:sub(1, 1)
    local rest = line:sub(2)

    if operand == "+" or operand == "-" then
      if from <= k and k <= to then
        len_offset = len_offset + (operand == "+" and 1 or -1)
        insert(diff_content, line)
        previous_kept = true
      else
        previous_kept = false

        -- If we want to apply the patch normally, we need to include every `-` line we skip as a normal line,
        -- since we want to keep that line.
        if not reverse then
          if operand == "-" then
            insert(diff_content, " " .. rest)
            previous_kept = true
          end
          -- If we want to apply the patch in reverse, we need to include every `+` line we skip as a normal line, since
          -- it's unchanged as far as the diff is concerned and should not be reversed.
          -- We also need to adapt the original line offset based on if we skip or not
        else
          if operand == "+" then
            insert(diff_content, " " .. rest)
            previous_kept = true
          end
          len_start = len_start + (operand == "-" and -1 or 1)
        end
      end
    elseif operand == "\\" then
      if previous_kept then
        insert(diff_content, line)
      end
    else
      insert(diff_content, line)
      previous_kept = true
    end
  end

  -- The hunk starts where it started in the original diff: `index_from` in the pristine file and
  -- `disk_from` in the working file. (Neogit uses `index_from` twice, which is off for hunks
  -- that add to an empty file: "-0,0 +1".)
  insert(
    diff_content,
    1,
    string.format("@@ -%d,%d +%d,%d @@", hunk.index_from, len_start, hunk.disk_from, len_start + len_offset)
  )

  -- The labels are not interpreted by `svn patch`, but the tab in front of them terminates the path
  insert(diff_content, 1, ("+++ %s\t(working copy)"):format(hunk.file))
  insert(diff_content, 1, ("--- %s\t(revision BASE)"):format(hunk.file))
  insert(diff_content, 1, string.rep("=", 67))
  insert(diff_content, 1, "Index: " .. hunk.file)

  return table.concat(diff_content, "\n") .. "\n"
end

return M
