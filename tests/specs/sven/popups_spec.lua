local util = require("tests.util.util")

describe("popups", function()
  local popups, state

  ---Makes `require("sven.popups.<name>")` return a module, like a popup that has been written
  ---@param name string
  ---@param module table|fun(): table
  local function implement(name, module)
    package.loaded["sven.popups." .. name] = nil
    package.preload["sven.popups." .. name] = type(module) == "function" and module
      or function()
        return module
      end
  end

  before_each(function()
    require("sven").setup { remember_settings = true, filewatcher = { enabled = false } }

    popups = require("sven.popups")
    state = require("sven.lib.state")
    state._reset()
  end)

  after_each(function()
    for _, name in ipairs(popups.names) do
      package.preload["sven.popups." .. name] = nil
      package.loaded["sven.popups." .. name] = nil
    end

    local popup = require("sven.lib.popup")
    if popup.is_open() then
      popup.instance:close()
    end
  end)

  describe("registry", function()
    it("knows the popups of sven", function()
      assert.are.same({ "help", "commit", "log", "diff", "update", "resolve" }, popups.names)
      assert.is_true(popups.exists("commit"))
      assert.is_false(popups.exists("push"))
    end)

    it("has a mapping for every popup", function()
      local config = require("sven.config")

      for _, name in ipairs(popups.names) do
        local mapping = popups.mapping_name(name)
        local keys = popups.mapping_for(mapping)

        assert.is_true(vim.tbl_contains(vim.tbl_values(config.values.mappings.popup), mapping), mapping)
        assert.is_table(keys, mapping)
        assert.are.same(1, #keys, mapping)
      end

      assert.are.same("CommitPopup", popups.mapping_name("commit"))
      assert.are.same({ "c" }, popups.mapping_for("CommitPopup"))
      assert.are.same({ "F" }, popups.mapping_for("UpdatePopup"))
    end)

    it("has a module for every popup it knows", function()
      for _, name in ipairs(popups.names) do
        local popup, reason, message = popups.load(name)

        assert.is_nil(reason, ("%s: %s %s"):format(name, tostring(reason), tostring(message)))
        assert.is_function(popup.create, name)
      end
    end)

    describe("with a popup that is registered but not written", function()
      -- Every popup of sven exists by now. One that does not is what a registered name without
      -- a module looks like.
      before_each(function()
        table.insert(popups.names, "ghost")
      end)

      after_each(function()
        for index, name in ipairs(popups.names) do
          if name == "ghost" then
            table.remove(popups.names, index)
            break
          end
        end
      end)

      it("tells it from an unknown one", function()
        local popup, reason = popups.load("ghost")
        assert.is_nil(popup)
        assert.are.same("missing", reason)

        popup, reason = popups.load("push")
        assert.is_nil(popup)
        assert.are.same("invalid", reason)
      end)

      it("says that it is not implemented yet", function()
        local notifications = util.capture_notifications(function()
          popups.open("ghost")()
        end)

        assert.are.same(1, #notifications)
        assert.are.same("The ghost popup is not implemented yet", notifications[1].message)
        assert.are.same(vim.log.levels.WARN, notifications[1].level)
      end)
    end)

    it("reports an unknown popup", function()
      local notifications = util.capture_notifications(function()
        popups.open("push")()
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match('Invalid popup "push"'))
      assert.are.same(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("opens a popup that exists", function()
      local created_with = nil
      implement("commit", {
        create = function(env)
          created_with = env or "nothing"
        end,
      })

      popups.open("commit")()
      assert.are.same("nothing", created_with)

      popups.open("commit", function(create)
        create { commit = "r5" }
      end)()
      assert.are.same({ commit = "r5" }, created_with)
    end)

    it("reports a popup that fails to load, with the reason", function()
      implement("log", function()
        error("this popup is broken")
      end)

      local notifications = util.capture_notifications(function()
        popups.open("log")()
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("Failed to load popup"))
      assert.is_truthy(notifications[1].message:match("this popup is broken"))
    end)

    it("reports a popup module without create()", function()
      implement("diff", {})

      local popup, reason, message = popups.load("diff")

      assert.is_nil(popup)
      assert.are.same("error", reason)
      assert.is_truthy(message:match("create%(%)"))
    end)
  end)

  describe("builder", function()
    local popup

    local function build()
      return popup
        .builder()
        :name("SvenSpecPopup")
        :switch("v", "verbose", "Show changed paths")
        :switch("s", "stop-on-copy", "Stop on copy", { enabled = true })
        :option("l", "limit", "", "Limit number of entries")
        :config("u", "sven.spec.variable")
        :group_heading("Log")
        :action("l", "current", function() end)
        :action("o", "other")
        :new_action_group("Other")
        :action("x", "example", function() end)
        :build()
    end

    ---@param p PopupData
    ---@param cli string
    local function arg(p, cli)
      for _, a in ipairs(p.state.args) do
        if a.cli == cli then
          return a
        end
      end
    end

    before_each(function()
      popup = require("sven.lib.popup")
    end)

    it("renders switches, options, variables and actions", function()
      local p = build()
      p:show()

      assert.are.same("SvenPopup", vim.bo.filetype)
      assert.is_true(popup.is_open())

      local lines = vim.tbl_map(function(line)
        return (line:gsub("%s+$", ""))
      end, vim.api.nvim_buf_get_lines(0, 0, -1, false))

      assert.are.same({
        "Variables",
        "u sven.spec.variable unset",
        "",
        "Arguments",
        "-v Show changed paths (--verbose)",
        "-s Stop on copy (--stop-on-copy)",
        "=l Limit number of entries (--limit=)",
        "",
        "Log            Other",
        "l current      x example",
        "o other",
      }, lines)

      p:close()
      assert.is_false(popup.is_open())
    end)

    it("collects the enabled arguments", function()
      local p = build()

      assert.are.same({ "--stop-on-copy" }, p:get_arguments())

      p:toggle_switch(arg(p, "verbose"))
      p:set_option(arg(p, "limit"), "25")

      assert.are.same({ "--verbose", "--stop-on-copy", "--limit=25" }, p:get_arguments())
      assert.are.same("--verbose --stop-on-copy --limit=25", p:to_cli())
    end)

    it("remembers switches and options between popups", function()
      local p = build()
      p:toggle_switch(arg(p, "verbose"))
      p:toggle_switch(arg(p, "stop-on-copy"))
      p:set_option(arg(p, "limit"), "25")

      assert.is_true(state.get { "SvenSpecPopup", "verbose" })
      assert.is_false(state.get { "SvenSpecPopup", "stop-on-copy" })
      assert.are.same("25", state.get { "SvenSpecPopup", "limit" })

      local again = build()
      assert.is_true(arg(again, "verbose").enabled)
      assert.is_false(arg(again, "stop-on-copy").enabled)
      assert.are.same("25", arg(again, "limit").value)
      assert.are.same({ "--verbose", "--limit=25" }, again:get_arguments())
    end)

    it("keeps variables in sven's own state", function()
      local variables = require("sven.lib.popup.variables")

      assert.is_false(variables.get("sven.spec.variable"):is_set())
      assert.are.same("", build().state.config[1].value)

      variables.set("sven.spec.variable", "42")

      local entry = variables.get("sven.spec.variable")
      assert.is_true(entry:is_set())
      assert.are.same("number", entry:type())
      assert.are.same(42, entry:read())
      assert.are.same("42", build().state.config[1].value)

      variables.unset("sven.spec.variable")
      assert.is_nil(variables.get("sven.spec.variable"):read())
    end)

    it("runs actions and closes the popup", function()
      local ran_with = nil
      local p = popup
        .builder()
        :name("SvenSpecActionPopup")
        :switch("v", "verbose", "Verbose", { enabled = true })
        :action("x", "example", function(self)
          ran_with = self:get_arguments()
        end)
        :build()
      p:show()

      vim.api.nvim_feedkeys("x", "x", false)

      assert.is_true(util.wait_for(function()
        return ran_with ~= nil
      end))
      assert.are.same({ "--verbose" }, ran_with)
      assert.is_false(popup.is_open())
    end)

    it("toggles a switch with its key", function()
      local p = build()
      p:show()

      vim.api.nvim_feedkeys("-v", "x", false)

      assert.is_true(util.wait_for(function()
        return arg(p, "verbose").enabled
      end))
    end)

    it("says that an action without a callback is not implemented", function()
      local p = build()
      p:show()

      local notifications = util.capture_notifications(function()
        vim.api.nvim_feedkeys("o", "x", false)
      end)

      assert.are.same(1, #notifications)
      assert.is_truthy(notifications[1].message:match("has not been implemented yet"))
    end)
  end)
end)
