-- Adapted from https://github.com/lewis6991/gitsigns.nvim/blob/main/lua/gitsigns/watcher.lua#L103

local logger = require("sven.logger")
local util = require("sven.lib.util")
local svn = require("sven.lib.svn")
local config = require("sven.config")
local a = require("sven.lib.async")

---Watches the administrative area of a working copy and refreshes the registered buffers when svn
---changes it. Every svn command that alters the working copy state (add, delete, changelist,
---commit, update, revert, resolve, ...) writes to `<root>/.svn/wc.db`, so that is the file to watch.
---
---A registered buffer must implement `id(): string` and `redraw()`.
---@class Watcher
---@field root string Working copy root
---@field admin_dir string The `.svn` directory of the working copy
---@field buffers table<string, table> Registered buffers, by their id
---@field running boolean
---@field fs_event_handler uv_fs_event_t
local Watcher = {}
Watcher.__index = Watcher

---@param root string
---@return Watcher
function Watcher.new(root)
  local instance = {
    buffers = {},
    root = root,
    admin_dir = vim.fs.joinpath(root, ".svn"),
    running = false,
    fs_event_handler = assert(vim.uv.new_fs_event()),
  }

  setmetatable(instance, Watcher)

  return instance
end

local instances = {}

---@param root string? Working copy root. Defaults to the root of the current repository.
---@return Watcher
function Watcher.instance(root)
  local dir = root or svn.repo.root
  if not dir or dir == "" then
    dir = vim.uv.cwd()
  end
  assert(dir, "Root must exist")

  dir = vim.fs.normalize(dir)

  if not instances[dir] then
    instances[dir] = Watcher.new(dir)
  end

  return instances[dir]
end

---@param buffer table Must implement `id()` and `redraw()`
---@return Watcher
function Watcher:register(buffer)
  logger.debug("[WATCHER] Registered buffer " .. buffer:id())

  self.buffers[buffer:id()] = buffer
  return self:start()
end

---@param buffer table
---@return Watcher
function Watcher:unregister(buffer)
  if not self.buffers[buffer:id()] then
    return self
  end
  self.buffers[buffer:id()] = nil

  logger.debug("[WATCHER] Unregistered buffer " .. buffer:id())

  if vim.tbl_isempty(self.buffers) and self.running then
    logger.debug("[WATCHER] No registered buffers - stopping")
    self:stop()
  end

  return self
end

---@return Watcher
function Watcher:start()
  if not config.values.filewatcher.enabled then
    return self
  end

  if self.running then
    return self
  end

  if not vim.uv.fs_stat(self.admin_dir) then
    logger.debug("[WATCHER] No administrative directory to watch: " .. self.admin_dir)
    return self
  end

  logger.debug("[WATCHER] Watching svn dir: " .. self.admin_dir)
  local ok, err = self.fs_event_handler:start(self.admin_dir, {}, self:fs_event_callback())
  if ok then
    self.running = true
  else
    logger.error(string.format("[WATCHER] Unable to watch %s: %s", self.admin_dir, err))
  end

  return self
end

---@return Watcher
function Watcher:stop()
  if not config.values.filewatcher.enabled then
    return self
  end

  if not self.running then
    return self
  end

  logger.debug("[WATCHER] Stopped watching svn dir: " .. self.admin_dir)
  self.running = false
  self.fs_event_handler:stop()
  return self
end

-- Only the working copy database is interesting. Its rollback journal, the pristine store and
-- the tmp directory change alongside it and would only cause duplicate refreshes.
local WATCH = {
  ["wc.db"] = true,
}

function Watcher:fs_event_callback()
  local refresh_debounced = util.debounce_trailing(
    200,
    a.void(util.throttle_by_id(function(info)
      logger.debug(info)
      self:dispatch_refresh()
    end, true))
  )

  return function(err, filename, events)
    if err then
      logger.error(string.format("[WATCHER] Svn dir update error: %s", err))
      return
    end

    -- Some platforms do not report which entry changed. Refresh to be safe.
    if filename ~= nil and not WATCH[vim.fs.basename(filename)] then
      return
    end

    local info = string.format(
      "[WATCHER] Svn dir update: '%s' %s",
      filename,
      vim.inspect(events, { indent = "", newline = " " })
    )

    refresh_debounced(info)
  end
end

---Refreshes the repository and redraws every registered buffer once it is done
function Watcher:dispatch_refresh()
  require("sven.lib.svn.repository").find(self.root):dispatch_refresh {
    source = "watcher",
    callback = function()
      for name, buffer in pairs(self.buffers) do
        logger.debug("[WATCHER] Dispatching redraw to " .. name)
        buffer:redraw()
      end
    end,
  }
end

return Watcher
