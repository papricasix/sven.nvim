---The Subversion backend. Submodules are loaded on first access:
---
---  local svn = require("sven.lib.svn")
---  svn.repo.state              -- state of the current working copy, see `sven.lib.svn.repository`
---  svn.cli.run { "cleanup" }   -- run any svn command
---  svn.changelist.stage { "src/main.c" }
---
---Everything that runs svn follows the calling convention described in `sven.lib.svn.cli`:
---it suspends the coroutine inside a `sven.lib.async` context and blocks outside of one.
---@class SvenLib
---@field repo       SvenRepo          The repository instance of the current working copy
---@field cli        SvenCli           Low level runner
---@field xml        SvenXml           XML reader for `--xml` output
---@field info       SvenInfo          `svn info`
---@field status     SvenStatus        `svn status`, parsed into the buckets of `repo.state`
---@field diff       SvenDiff          `svn diff`, parsed into Neogit's diff shape
---@field changelist SvenChangelist    Staging (the staging changelist) and changelists in general
---@field revert     SvenRevert        Discarding changes: files, hunks, unversioned paths
---@field commit     SvenCommit        `svn commit`
---@field update     SvenUpdate        `svn update`
---@field resolve    SvenResolve       `svn resolve`
---@field log        SvenLog           `svn log`
---@field cat        SvenCat           `svn cat`
---@field blame      SvenBlame         `svn blame`
local Svn = {}

setmetatable(Svn, {
  __index = function(_, k)
    if k == "repo" then
      return require("sven.lib.svn.repository").instance()
    else
      return require("sven.lib.svn." .. k)
    end
  end,
})

return Svn
