---A small, tolerant XML reader for the output of `svn --xml`.
---
---It understands elements, attributes, text, CDATA and entities, and skips declarations,
---comments and doctypes. It does not validate: truncated or mismatched input yields whatever
---could be read instead of an error, because a killed or failing svn process still hands us
---partial output.
---
---  local xml = require("sven.lib.svn.xml")
---  local root = xml.parse('<log><logentry revision="3"><author>me</author></logentry></log>')
---  local entry = root:find("logentry")
---  entry.attrs.revision    --> "3"
---  entry:text_of("author") --> "me"
---@class SvenXml
local M = {}

---@class SvenXmlNode
---@field tag string Element name. The synthetic root returned by `parse` has the tag "#document".
---@field attrs table<string, string> Attributes, entity decoded
---@field children SvenXmlNode[] Child elements, in document order
---@field text string Text directly inside the element (not of its children), entity decoded, untrimmed
local Node = {}
Node.__index = Node

---@param tag string
---@param attrs table<string, string>|nil
---@return SvenXmlNode
local function new_node(tag, attrs)
  return setmetatable({ tag = tag, attrs = attrs or {}, children = {}, text = "" }, Node)
end

---First direct child with the given tag
---@param tag string
---@return SvenXmlNode|nil
function Node:find(tag)
  for _, child in ipairs(self.children) do
    if child.tag == tag then
      return child
    end
  end
end

---All direct children with the given tag (all children when `tag` is nil)
---@param tag string|nil
---@return SvenXmlNode[]
function Node:all(tag)
  if not tag then
    return self.children
  end

  local result = {}
  for _, child in ipairs(self.children) do
    if child.tag == tag then
      table.insert(result, child)
    end
  end

  return result
end

---Follows a path of tags through first children: `node:path("repository", "root")`
---@param ... string
---@return SvenXmlNode|nil
function Node:path(...)
  local node = self
  for _, tag in ipairs { ... } do
    node = node:find(tag)
    if not node then
      return nil
    end
  end

  return node
end

---Text of the first direct child with the given tag
---@param tag string
---@return string|nil
function Node:text_of(tag)
  local child = self:find(tag)
  return child and child.text or nil
end

---Attribute value
---@param name string
---@return string|nil
function Node:attr(name)
  return self.attrs[name]
end

---Every descendant with the given tag, depth first, in document order
---@param tag string
---@param result SvenXmlNode[]|nil
---@return SvenXmlNode[]
function Node:descendants(tag, result)
  result = result or {}
  for _, child in ipairs(self.children) do
    if child.tag == tag then
      table.insert(result, child)
    end
    child:descendants(tag, result)
  end

  return result
end

local named_entities = {
  lt = "<",
  gt = ">",
  amp = "&",
  quot = '"',
  apos = "'",
}

---@param codepoint number
---@return string
local function utf8(codepoint)
  if codepoint < 0x80 then
    return string.char(codepoint)
  elseif codepoint < 0x800 then
    return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
  elseif codepoint < 0x10000 then
    return string.char(
      0xE0 + math.floor(codepoint / 0x1000),
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    )
  elseif codepoint < 0x110000 then
    return string.char(
      0xF0 + math.floor(codepoint / 0x40000),
      0x80 + math.floor(codepoint / 0x1000) % 0x40,
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    )
  end

  return ""
end

---Decodes `&lt;`, `&#10;`, `&#x1F;` and friends. Unknown entities are left untouched.
---@param s string
---@return string
function M.decode(s)
  if not s:find("&", 1, true) then
    return s
  end

  local decoded = s:gsub("&(#?[%w]+);", function(entity)
    if entity:sub(1, 1) == "#" then
      local codepoint
      if entity:sub(2, 2) == "x" or entity:sub(2, 2) == "X" then
        codepoint = tonumber(entity:sub(3), 16)
      else
        codepoint = tonumber(entity:sub(2), 10)
      end

      if codepoint then
        return utf8(codepoint)
      end
    elseif named_entities[entity] then
      return named_entities[entity]
    end
  end)

  return decoded
end

---Reads the attributes of a start tag.
---@param s string the document
---@param pos number position right after the element name
---@return table<string, string> attrs
---@return number pos position right after the closing `>` of the tag
---@return boolean self_closing
local function parse_attributes(s, pos)
  local attrs = {}
  local len = #s

  while pos <= len do
    local _, ws_end = s:find("^%s*", pos)
    pos = ws_end + 1

    local c = s:sub(pos, pos)
    if c == ">" then
      return attrs, pos + 1, false
    elseif c == "/" then
      local close = s:find(">", pos, true)
      return attrs, (close or len) + 1, true
    elseif c == "" then
      break
    end

    local name_start, name_end = s:find("^[^%s=/>]+", pos)
    if not name_start then
      -- Something unexpected. Skip the character to make progress.
      pos = pos + 1
    else
      local name = s:sub(name_start, name_end)
      pos = name_end + 1

      local _, eq_end = s:find("^%s*=%s*", pos)
      if eq_end then
        pos = eq_end + 1
        local quote = s:sub(pos, pos)
        if quote == '"' or quote == "'" then
          local value_end = s:find(quote, pos + 1, true)
          if not value_end then
            attrs[name] = M.decode(s:sub(pos + 1))
            return attrs, len + 1, false
          end

          attrs[name] = M.decode(s:sub(pos + 1, value_end - 1))
          pos = value_end + 1
        else
          -- Unquoted value
          local _, value_end = s:find("^[^%s/>]*", pos)
          attrs[name] = M.decode(s:sub(pos, value_end))
          pos = value_end + 1
        end
      else
        -- Attribute without a value
        attrs[name] = ""
      end
    end
  end

  return attrs, len + 1, false
end

---Parses a document.
---@param input string|string[] The document, or its lines
---@return SvenXmlNode root A synthetic "#document" node whose children are the top level elements
function M.parse(input)
  local s = type(input) == "table" and table.concat(input, "\n") or input --[[@as string]]
  local root = new_node("#document")
  local stack = { root }
  local pos = 1
  local len = #s

  local function current()
    return stack[#stack]
  end

  local function add_text(text)
    if text ~= "" then
      local node = current()
      node.text = node.text .. text
    end
  end

  while pos <= len do
    local lt = s:find("<", pos, true)
    if not lt then
      add_text(M.decode(s:sub(pos)))
      break
    end

    if lt > pos then
      add_text(M.decode(s:sub(pos, lt - 1)))
    end

    if s:sub(lt, lt + 3) == "<!--" then
      local close = s:find("-->", lt + 4, true)
      pos = close and close + 3 or len + 1
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local close = s:find("]]>", lt + 9, true)
      add_text(s:sub(lt + 9, (close or len + 1) - 1))
      pos = close and close + 3 or len + 1
    elseif s:sub(lt, lt + 1) == "<?" then
      local close = s:find("?>", lt + 2, true)
      pos = close and close + 2 or len + 1
    elseif s:sub(lt, lt + 1) == "<!" then
      local close = s:find(">", lt + 2, true)
      pos = close and close + 1 or len + 1
    elseif s:sub(lt, lt + 1) == "</" then
      local close = s:find(">", lt + 2, true)
      local tag = vim.trim(s:sub(lt + 2, (close or len + 1) - 1))

      -- Close the nearest open element with that name. Unknown end tags are ignored.
      for i = #stack, 2, -1 do
        if stack[i].tag == tag then
          for _ = #stack, i, -1 do
            table.remove(stack)
          end
          break
        end
      end

      pos = close and close + 1 or len + 1
    else
      local name_start, name_end = s:find("^[^%s/>]+", lt + 1)
      if not name_start then
        -- A stray "<". Treat it as text.
        add_text("<")
        pos = lt + 1
      else
        local attrs, next_pos, self_closing = parse_attributes(s, name_end + 1)
        local node = new_node(s:sub(name_start, name_end), attrs)
        table.insert(current().children, node)

        if not self_closing then
          table.insert(stack, node)
        end

        pos = next_pos
      end
    end
  end

  return root
end

return M
