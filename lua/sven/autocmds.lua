local M = {}

local api = vim.api

function M.setup()
  local status_buffer = require("sven.buffers.status")
  local svn = require("sven.lib.svn")
  local group = require("sven").autocmd_group

  api.nvim_create_autocmd({ "ColorScheme" }, {
    callback = function()
      -- Scheduled, so that every other ColorScheme handler has run first. Sven's groups link to
      -- their Neogit counterparts when those exist, and Neogit (re)defines its groups on this
      -- very event.
      vim.schedule(function()
        local config = require("sven.config")
        local highlight = require("sven.lib.hl")

        highlight.setup(config.values)
      end)
    end,
    group = group,
  })

  api.nvim_create_autocmd("SessionLoadPost", {
    callback = function()
      vim.schedule(function()
        for _, buf in ipairs(api.nvim_list_bufs()) do
          local buf_name = api.nvim_buf_get_name(buf)
          if buf_name:match("Sven%w+") then
            api.nvim_buf_delete(buf, { force = true })
          end
        end
      end)
    end,
    group = group,
  })

  local autocmd_disabled = false
  api.nvim_create_autocmd({ "BufWritePost", "ShellCmdPost", "VimResume" }, {
    -- Must not return anything: an autocmd whose callback returns a truthy value is deleted,
    -- and a function made with `async.void` returns its task.
    callback = function(o)
      if autocmd_disabled or api.nvim_get_option_value("filetype", { buf = o.buf }):match("^Sven") then
        return
      end

      -- Wherever the status buffer is shown: the file may have been written in another tab,
      -- or in a window with a working directory of its own
      local instance = status_buffer.shown()
      if not instance then
        return
      end

      if o.event == "BufWritePost" then
        local path = o.file ~= "" and svn.repo:relpath(o.file) or nil
        if path then
          -- Only the diff of the written file is stale, every other cached diff is kept
          instance:dispatch_refresh(
            { update_diffs = { "*:" .. path } },
            string.format("%s:%s", o.event, path)
          )
        end
      else
        -- A shell command or a suspended session may have touched anything
        instance:dispatch_refresh(nil, o.event)
      end
    end,
    group = group,
  })

  --- vimpgrep creates and deletes lots of buffers so attaching to each one will
  --- waste lots of resource and even slow down vimgrep.
  api.nvim_create_autocmd({ "QuickFixCmdPre", "QuickFixCmdPost" }, {
    group = group,
    pattern = "*vimgrep*",
    callback = function(args)
      autocmd_disabled = args.event == "QuickFixCmdPre"
    end,
  })

  -- Ensure vim buffers are updated
  api.nvim_create_autocmd("User", {
    pattern = "SvenStatusRefreshed",
    callback = function()
      vim.cmd("set autoread | checktime")
    end,
    group = group,
  })
end

return M
