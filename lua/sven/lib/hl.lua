--#region TYPES

---@class HiSpec
---@field fg string
---@field bg string
---@field gui string
---@field sp string
---@field blend integer
---@field default boolean

---@class HiLinkSpec
---@field force boolean
---@field default boolean

--#endregion

local Color = require("sven.lib.color").Color
local hl_store
local M = {}

---@param dec number
---@return string
local function to_hex(dec)
  local hex = string.format("%x", dec)
  if #hex < 6 then
    return string.rep("0", 6 - #hex) .. hex
  else
    return hex
  end
end

---@param name string Syntax group name.
---@return string|nil
local function get_fg(name)
  local color = vim.api.nvim_get_hl(0, { name = name })
  if color["link"] then
    return get_fg(color["link"])
  elseif color["reverse"] and color["bg"] then
    return "#" .. to_hex(color["bg"])
  elseif color["fg"] then
    return "#" .. to_hex(color["fg"])
  end
end

---@param name string Syntax group name.
---@return string|nil
local function get_bg(name)
  local color = vim.api.nvim_get_hl(0, { name = name })
  if color["link"] then
    return get_bg(color["link"])
  elseif color["reverse"] and color["fg"] then
    return "#" .. to_hex(color["fg"])
  elseif color["bg"] then
    return "#" .. to_hex(color["bg"])
  end
end

---@class SvenColorPalette
---@field bg0        string  Darkest background color
---@field bg1        string  Second darkest background color
---@field bg2        string  Second lightest background color
---@field bg3        string  Lightest background color
---@field grey       string  middle grey shade for foreground
---@field white      string  Foreground white (main text)
---@field red        string  Foreground red
---@field bg_red     string  Background red
---@field line_red   string  Cursor line highlight for red regions, like deleted hunks
---@field orange     string  Foreground orange
---@field bg_orange  string  background orange
---@field yellow     string  Foreground yellow
---@field bg_yellow  string  background yellow
---@field green      string  Foreground green
---@field bg_green   string  Background green
---@field line_green string  Cursor line highlight for green regions, like added hunks
---@field cyan       string  Foreground cyan
---@field bg_cyan    string  Background cyan
---@field blue       string  Foreground blue
---@field bg_blue    string  Background blue
---@field purple     string  Foreground purple
---@field bg_purple  string  Background purple
---@field md_purple  string  Background _medium_ purple. Lighter than bg_purple.
---@field inline_green string  Background for inline add word-diff highlights
---@field inline_red   string  Background for inline delete word-diff highlights
---@field italic     boolean enable italics?
---@field bold       boolean enable bold?
---@field underline  boolean enable underline?

-- stylua: ignore start
---@param config SvenConfig
---@return SvenColorPalette
local function make_palette(config)
  local bg        = Color.from_hex(get_bg("Normal") or (vim.o.bg == "dark" and "#22252A" or "#eeeeee"))
  local fg        = Color.from_hex((vim.o.bg == "dark" and "#fcfcfc" or "#22252A"))
  local red       = Color.from_hex(config.highlight.red or get_fg("ErrorMsg") or "#E06C75")
  local orange    = Color.from_hex(config.highlight.orange or get_fg("SpecialChar") or "#ffcb6b")
  local yellow    = Color.from_hex(config.highlight.yellow or get_fg("PreProc") or "#FFE082")
  local green     = Color.from_hex(config.highlight.green or get_fg("String") or "#C3E88D")
  local cyan      = Color.from_hex(config.highlight.cyan or get_fg("Operator") or "#89ddff")
  local blue      = Color.from_hex(config.highlight.blue or get_fg("Macro") or "#82AAFF")
  local purple    = Color.from_hex(config.highlight.purple or get_fg("Include") or "#C792EA")

  local bg_factor = vim.o.bg == "dark" and 1 or -1

  local default   = {
    bg0          = bg:to_css(),
    bg1          = bg:shade(bg_factor * 0.019):to_css(),
    bg2          = bg:shade(bg_factor * 0.065):to_css(),
    bg3          = bg:shade(bg_factor * 0.11):to_css(),
    grey         = bg:shade(bg_factor * 0.4):to_css(),
    white        = fg:to_css(),
    red          = red:to_css(),
    bg_red       = red:shade(bg_factor * -0.18):to_css(),
    line_red     = get_bg("DiffDelete") or red:shade(bg_factor * -0.6):set_saturation(0.4):to_css(),
    orange       = orange:to_css(),
    bg_orange    = orange:shade(bg_factor * -0.17):to_css(),
    yellow       = yellow:to_css(),
    bg_yellow    = yellow:shade(bg_factor * -0.17):to_css(),
    green        = green:to_css(),
    bg_green     = green:shade(bg_factor * -0.18):to_css(),
    line_green   = get_bg("DiffAdd") or green:shade(bg_factor * -0.72):set_saturation(0.2):to_css(),
    cyan         = cyan:to_css(),
    bg_cyan      = cyan:shade(bg_factor * -0.18):to_css(),
    blue         = blue:to_css(),
    bg_blue      = blue:shade(bg_factor * -0.18):to_css(),
    purple       = purple:to_css(),
    bg_purple    = purple:shade(bg_factor * -0.18):to_css(),
    md_purple    = purple:shade(0.18):to_css(),
    inline_green = green:shade(bg_factor * -0.2):set_saturation(0.65):to_css(),
    inline_red   = red:shade(bg_factor * 0.3):set_saturation(0.65):to_css(),
    italic       = true,
    bold         = true,
    underline    = true,
  }

  return vim.tbl_extend("keep", config.highlight or {}, default)
end
-- stylua: ignore end

---@param hl_name string
---@return table definition of the group, empty when it is not defined
local function get_hl(hl_name)
  local exists, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, create = false })
  if not exists or type(hl) ~= "table" then
    return {}
  end

  return hl
end

-- https://github.com/lewis6991/gitsigns.nvim/blob/1e01b2958aebb79f1c33e7427a1bac131a678e0d/lua/gitsigns/highlight.lua#L250
--- @param hl_name string
--- @return boolean
local function is_set(hl_name)
  return not vim.tbl_isempty(get_hl(hl_name))
end

---Every definition sven gave to its groups, to tell them apart from definitions made by the user
---or a colorscheme: only groups that carry one of sven's own definitions are re-evaluated.
---
---All of them are remembered, not just the latest: `:hi clear` brings back the default link a
---group once had, even when it was redefined since.
---@type table<string, table<string, boolean>>
local owned = {}

---@param hl table
---@return string
local function fingerprint(hl)
  local copy = vim.deepcopy(hl)
  -- `:hi clear` restores default links but drops the flag
  copy.default = nil

  -- Keys come out sorted, so equal definitions have equal fingerprints
  return vim.inspect(copy, { newline = "", indent = "" })
end

---@param group string
---@return boolean whether the group currently has a definition sven gave it
local function is_owned(group)
  return owned[group] ~= nil and owned[group][fingerprint(get_hl(group))] == true
end

---The Neogit group a sven group corresponds to: `SvenDiffAdd` -> `NeogitDiffAdd`
---@param group string
---@return string
function M.neogit_group(group)
  return "Neogit" .. group:sub(#"Sven" + 1)
end

---Defines a sven group, unless the user or the colorscheme already did.
---
---When the matching Neogit group exists, the sven group links to it, so colorschemes with Neogit
---support (and a configured Neogit) style sven automatically. Otherwise `hl` is used, which is
---derived from the same palette Neogit uses.
---@param group string
---@param hl table
local function define(group, hl)
  local redefine = false
  if is_set(group) then
    if not is_owned(group) then
      return
    end

    redefine = true
  end

  local spec
  local neogit = M.neogit_group(group)
  if is_set(neogit) then
    spec = { link = neogit }
  else
    spec = vim.deepcopy(hl)
  end

  -- A group nobody defined is defined as a default, which never overrides anything. Replacing
  -- our own earlier definition has to be forced: `default` would keep it. (Clearing the group
  -- first is not an option, Neovim then ignores default definitions for it.)
  if not redefine then
    spec.default = true
  end

  vim.api.nvim_set_hl(0, group, spec)

  owned[group] = owned[group] or {}
  owned[group][fingerprint(get_hl(group))] = true
end

---Defines all highlight groups. Safe to call again: it is re-run on `ColorScheme`.
---@param config SvenConfig
function M.setup(config)
  local palette = make_palette(config)

  -- stylua: ignore
  hl_store = {
    SvenGraphAuthor              = { fg = palette.orange, ctermfg = 3 },
    SvenGraphRed                 = { fg = palette.red, ctermfg = 1 },
    SvenGraphWhite               = { fg = palette.white, ctermfg = 7 },
    SvenGraphYellow              = { fg = palette.yellow, ctermfg = 3 },
    SvenGraphGreen               = { fg = palette.green, ctermfg = 2 },
    SvenGraphCyan                = { fg = palette.cyan, ctermfg = 6 },
    SvenGraphBlue                = { fg = palette.blue, ctermfg = 4 },
    SvenGraphPurple              = { fg = palette.purple, ctermfg = 5 },
    SvenGraphGray                = { fg = palette.grey, ctermfg = 7 },
    SvenGraphOrange              = { fg = palette.orange, ctermfg = 3 },
    SvenGraphBoldOrange          = { fg = palette.orange, bold = palette.bold, ctermfg = 3 },
    SvenGraphBoldRed             = { fg = palette.red, bold = palette.bold, ctermfg = 1 },
    SvenGraphBoldWhite           = { fg = palette.white, bold = palette.bold, ctermfg = 7 },
    SvenGraphBoldYellow          = { fg = palette.yellow, bold = palette.bold, ctermfg = 3 },
    SvenGraphBoldGreen           = { fg = palette.green, bold = palette.bold, ctermfg = 2 },
    SvenGraphBoldCyan            = { fg = palette.cyan, bold = palette.bold, ctermfg = 6 },
    SvenGraphBoldBlue            = { fg = palette.blue, bold = palette.bold, ctermfg = 4 },
    SvenGraphBoldPurple          = { fg = palette.purple, bold = palette.bold, ctermfg = 5 },
    SvenGraphBoldGray            = { fg = palette.grey, bold = palette.bold, ctermfg = 7 },
    SvenSubtleText               = { link = "Comment" },
    SvenNormal                   = { link = "Normal" },
    SvenNormalFloat              = { link = "SvenNormal" },
    SvenFloatBorder              = { link = "SvenNormalFloat" },
    SvenSignColumn               = { fg = "None", bg = "None" },
    SvenCursorLine               = { link = "CursorLine" },
    SvenCursorLineNr             = { link = "CursorLineNr" },
    SvenHunkMergeHeader          = { fg = palette.bg2, bg = palette.grey, bold = palette.bold, ctermfg = 4 },
    SvenHunkMergeHeaderHighlight = { fg = palette.bg0, bg = palette.bg_cyan, bold = palette.bold, ctermfg = 4 },
    SvenHunkMergeHeaderCursor    = { fg = palette.bg0, bg = palette.bg_cyan, bold = palette.bold, ctermfg = 4 },
    SvenHunkHeader               = { fg = palette.bg0, bg = palette.grey, bold = palette.bold, ctermfg = 3 },
    SvenHunkHeaderHighlight      = { fg = palette.bg0, bg = palette.md_purple, bold = palette.bold, ctermfg = 3 },
    SvenHunkHeaderCursor         = { fg = palette.bg0, bg = palette.md_purple, bold = palette.bold, ctermfg = 3 },
    SvenDiffContext              = { bg = palette.bg1 },
    SvenDiffContextHighlight     = { bg = palette.bg2 },
    SvenDiffContextCursor        = { bg = palette.bg1 },
    SvenDiffAdditions            = { fg = palette.bg_green, ctermfg = 2 },
    SvenDiffAdd                  = { bg = palette.line_green, fg = palette.bg_green, ctermfg = 2 },
    SvenDiffAddHighlight         = { bg = palette.line_green, fg = palette.green, ctermfg = 2 },
    SvenDiffAddCursor            = { bg = palette.bg1, fg = palette.green, ctermfg = 2 },
    SvenDiffDeletions            = { fg = palette.bg_red, ctermfg = 1 },
    SvenDiffDelete               = { bg = palette.line_red, fg = palette.bg_red, ctermfg = 1 },
    SvenDiffDeleteHighlight      = { bg = palette.line_red, fg = palette.red, ctermfg = 1 },
    SvenDiffDeleteCursor         = { bg = palette.bg1, fg = palette.red, ctermfg = 1 },
    SvenDiffAddInline            = { bg = palette.inline_green, fg = palette.line_green, bold = palette.bold },
    SvenDiffDeleteInline         = { bg = palette.inline_red, fg = palette.bg0, bold = palette.bold },
    SvenPopupSectionTitle        = { link = "Function" },
    SvenPopupBranchName          = { link = "String" },
    SvenPopupBold                = { bold = palette.bold },
    SvenPopupSwitchKey           = { fg = palette.purple, ctermfg = 5 },
    SvenPopupSwitchEnabled       = { link = "SpecialChar" },
    SvenPopupSwitchDisabled      = { link = "SvenSubtleText" },
    SvenPopupOptionKey           = { fg = palette.purple, ctermfg = 5 },
    SvenPopupOptionEnabled       = { link = "SpecialChar" },
    SvenPopupOptionDisabled      = { link = "SvenSubtleText" },
    SvenPopupConfigKey           = { fg = palette.purple, ctermfg = 5 },
    SvenPopupConfigEnabled       = { link = "SpecialChar" },
    SvenPopupConfigDisabled      = { link = "SvenSubtleText" },
    SvenPopupActionKey           = { fg = palette.purple, ctermfg = 5 },
    SvenPopupActionDisabled      = { link = "SvenSubtleText" },
    SvenFilePath                 = { fg = palette.blue, italic = palette.italic, ctermfg = 3 },
    SvenCommitViewHeader         = { bg = palette.bg_cyan, fg = palette.bg0, ctermfg = 7 },
    SvenCommitViewDescription    = { link = "String" },
    SvenDiffHeader               = { bg = palette.bg3, fg = palette.blue, bold = palette.bold, ctermfg = 3 },
    SvenDiffHeaderHighlight      = { bg = palette.bg3, fg = palette.orange, bold = palette.bold, ctermfg = 3 },
    SvenCommandText              = { link = "SvenSubtleText" },
    SvenCommandTime              = { link = "SvenSubtleText" },
    SvenCommandCodeNormal        = { link = "String" },
    SvenCommandCodeError         = { link = "Error" },
    SvenBranch                   = { fg = palette.blue, bold = palette.bold, ctermfg = 4 },
    SvenBranchHead               = { fg = palette.blue, bold = palette.bold, underline = palette.underline, ctermfg = 4 },
    SvenRemote                   = { fg = palette.green, bold = palette.bold, ctermfg = 2 },
    SvenUnpulledFrom             = { fg = palette.bg_purple, bold = palette.bold, ctermfg = 5 },
    SvenStatusHEAD               = {},
    SvenObjectId                 = { link = "SvenSubtleText" },
    SvenFold                     = { fg = "None", bg = "None" },
    SvenFoldColumn               = { fg = "None", bg = "None" },
    SvenWinSeparator             = { link = "WinSeparator" },
    SvenChangeModified           = { fg = palette.bg_blue, bold = palette.bold, italic = palette.italic, ctermfg = 4 },
    SvenChangeAdded              = { fg = palette.bg_green, bold = palette.bold, italic = palette.italic, ctermfg = 2 },
    SvenChangeDeleted            = { fg = palette.bg_red, bold = palette.bold, italic = palette.italic, ctermfg = 1 },
    SvenChangeRenamed            = { fg = palette.bg_purple, bold = palette.bold, italic = palette.italic, ctermfg = 5 },
    SvenChangeUpdated            = { fg = palette.bg_orange, bold = palette.bold, italic = palette.italic, ctermfg = 3 },
    SvenChangeCopied             = { fg = palette.bg_cyan, bold = palette.bold, italic = palette.italic, ctermfg = 6 },
    SvenChangeUnmerged           = { fg = palette.bg_yellow, bold = palette.bold, italic = palette.italic, ctermfg = 3 },
    SvenChangeNewFile            = { fg = palette.bg_green, bold = palette.bold, italic = palette.italic, ctermfg = 2 },
    SvenSectionHeader            = { fg = palette.bg_purple, bold = palette.bold, ctermfg = 5 },
    SvenSectionHeaderCount       = {},
    SvenUntrackedfiles           = { link = "SvenSectionHeader" },
    SvenUnstagedchanges          = { link = "SvenSectionHeader" },
    SvenUnmergedchanges          = { link = "SvenSectionHeader" },
    SvenUnpulledchanges          = { link = "SvenSectionHeader" },
    SvenRecentcommits            = { link = "SvenSectionHeader" },
    SvenStagedchanges            = { link = "SvenSectionHeader" },
    SvenTagName                  = { fg = palette.yellow, ctermfg = 3 },
    SvenTagDistance              = { fg = palette.cyan, ctermfg = 6 },
    SvenFloatHeader              = { bg = palette.bg0, bold = palette.bold, ctermfg = 5 },
    SvenFloatHeaderHighlight     = { bg = palette.bg2, fg = palette.cyan, bold = palette.bold, ctermfg = 5 },
    SvenActiveItem               = { bg = palette.bg_orange, fg = palette.bg0, bold = palette.bold, ctermfg = 5 },
  }

  -- Groups that only exist in sven. They have no Neogit counterpart to link to, so they link to
  -- the closest sven group, which in turn follows Neogit when it can.
  -- stylua: ignore
  local svn_store = {
    -- One group per `item.status`: "SvenChange" .. capitalized status
    SvenChangeReplaced           = { link = "SvenChangeRenamed" },
    SvenChangeMissing            = { link = "SvenChangeDeleted" },
    SvenChangeConflicted         = { link = "SvenChangeUnmerged" },
    SvenChangeObstructed         = { link = "SvenChangeUnmerged" },
    SvenChangeIncomplete         = { link = "SvenChangeUpdated" },
    SvenChangeExternal           = { link = "SvenChangeCopied" },
    SvenChangeIgnored            = { link = "SvenSubtleText" },
    SvenChangeUnversioned        = { fg = "None" },
    -- Section headers of the status buffer
    SvenConflicts                = { link = "SvenUnmergedchanges" },
    SvenUnversionedfiles         = { link = "SvenUntrackedfiles" },
    SvenChanges                  = { link = "SvenUnstagedchanges" },
    SvenChangelist               = { link = "SvenSectionHeader" },
    SvenChangelistName           = { link = "SvenBranch" },
    SvenIncomingchanges          = { link = "SvenUnpulledchanges" },
    -- Header of the status buffer and revision ids
    SvenUrl                      = { link = "SvenRemote" },
    SvenRevision                 = { link = "SvenObjectId" },
    -- Blame gutter
    SvenBlameRevision            = { link = "SvenObjectId" },
    SvenBlameAuthor              = { link = "SvenGraphAuthor" },
    SvenBlameDate                = { link = "SvenSubtleText" },
    SvenBlameUncommitted         = { link = "SvenSubtleText" },
  }

  for group, hl in pairs(hl_store) do
    define(group, hl)
  end

  for group, hl in pairs(svn_store) do
    define(group, hl)
  end
end

return M
