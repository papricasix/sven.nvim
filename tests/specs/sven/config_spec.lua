local config = require("sven.config")

describe("config", function()
  before_each(function()
    config.values = config.get_default_values()
  end)

  describe("defaults", function()
    it("are valid", function()
      assert.are.same({}, config.validate_config())
    end)

    it("stage into the sven-staged changelist with the svn on the PATH", function()
      assert.are.same("sven-staged", config.values.staging_changelist)
      assert.are.same("sven-staged", config.get_staging_changelist())
      assert.are.same("svn", config.get_svn_executable())
    end)

    it("define the status mappings", function()
      local expected = {
        ["<tab>"] = "Toggle",
        ["za"] = "Toggle",
        ["1"] = "Depth1",
        ["2"] = "Depth2",
        ["3"] = "Depth3",
        ["4"] = "Depth4",
        ["s"] = "Stage",
        ["S"] = "StageUnstaged",
        ["<c-s>"] = "StageAll",
        ["u"] = "Unstage",
        ["U"] = "UnstageStaged",
        ["x"] = "Discard",
        ["B"] = "Blame",
        ["<cr>"] = "GoToFile",
        ["<c-r>"] = "RefreshBuffer",
        ["$"] = "CommandHistory",
        ["q"] = "Close",
        ["Y"] = "YankSelected",
        ["{"] = "GoToPreviousHunkHeader",
        ["}"] = "GoToNextHunkHeader",
        ["<c-n>"] = "NextSection",
        ["<c-p>"] = "PreviousSection",
        ["j"] = "MoveDown",
        ["k"] = "MoveUp",
      }

      for key, command in pairs(expected) do
        assert.are.same(command, config.values.mappings.status[key], key)
      end
    end)

    it("define the popup mappings", function()
      assert.are.same({
        ["?"] = "HelpPopup",
        ["c"] = "CommitPopup",
        ["l"] = "LogPopup",
        ["d"] = "DiffPopup",
        ["F"] = "UpdatePopup",
        ["r"] = "ResolvePopup",
      }, config.values.mappings.popup)
    end)

    it("define the commit editor mappings", function()
      assert.are.same("Submit", config.values.mappings.commit_editor["<c-c><c-c>"])
      assert.are.same("Abort", config.values.mappings.commit_editor["<c-c><c-k>"])
      assert.are.same("Close", config.values.mappings.commit_editor["q"])
      assert.are.same("Submit", config.values.mappings.commit_editor_I["<c-c><c-c>"])
      assert.are.same("Abort", config.values.mappings.commit_editor_I["<c-c><c-k>"])
    end)

    it("describe a section for every bucket", function()
      for _, section in ipairs { "conflicts", "unversioned", "changes", "staged", "changelists", "recent" } do
        assert.is_boolean(config.values.sections[section].folded, section)
        assert.is_boolean(config.values.sections[section].hidden, section)
      end
    end)

    it("name every mode svn status prints", function()
      for _, mode in ipairs { "M", "A", "D", "R", "C", "!", "?", "~", "X", "I" } do
        assert.is_string(config.values.status.mode_text[mode], mode)
      end
    end)
  end)

  describe("#setup", function()
    it("merges user options into the defaults", function()
      config.setup {
        staging_changelist = "ready",
        kind = "split",
        status = { recent_commit_count = 3 },
      }

      assert.are.same("ready", config.get_staging_changelist())
      assert.are.same("split", config.values.kind)
      assert.are.same(3, config.values.status.recent_commit_count)
      -- Untouched neighbours keep their defaults
      assert.are.same(3, config.values.status.mode_padding)
      assert.are.same("tab", config.values.commit_editor.kind)
    end)

    it("accepts keys it does not know, for views to read their own options", function()
      config.setup { blame = { date_format = "%Y" } }

      assert.are.same("%Y", config.values.blame.date_format)
    end)

    it("removes mappings that are set to false", function()
      config.setup { mappings = { status = { ["s"] = false }, popup = { ["c"] = false } } }

      assert.is_nil(config.values.mappings.status["s"])
      assert.is_nil(config.values.mappings.popup["c"])
      assert.are.same("Unstage", config.values.mappings.status["u"])
    end)

    it("adds and rebinds mappings", function()
      config.setup { mappings = { status = { ["gs"] = "Stage", ["s"] = "Unstage" } } }

      assert.are.same("Stage", config.values.mappings.status["gs"])
      assert.are.same("Unstage", config.values.mappings.status["s"])
    end)

    it("drops all default mappings when asked to", function()
      config.setup { use_default_keymaps = false, mappings = { status = { ["s"] = "Stage" } } }

      assert.are.same({ ["s"] = "Stage" }, config.values.mappings.status)
      assert.are.same({}, config.values.mappings.popup)
    end)

    it("rejects an unknown window kind", function()
      assert.has_error(function()
        config.setup { kind = "sideways" }
      end)
    end)

    it("rejects an unknown status command", function()
      assert.has_error(function()
        config.setup { mappings = { status = { ["s"] = "Frobnicate" } } }
      end)
    end)

    it("rejects an unknown popup", function()
      assert.has_error(function()
        config.setup { mappings = { popup = { ["P"] = "PushPopup" } } }
      end)
    end)

    it("rejects an unusable staging changelist", function()
      assert.has_error(function()
        config.setup { staging_changelist = "" }
      end)

      config.values = config.get_default_values()
      assert.has_error(function()
        config.setup { staging_changelist = 42 }
      end)
    end)

    it("accepts functions as status mappings", function()
      local fn = function() end
      config.setup { mappings = { status = { ["gx"] = fn } } }

      assert.are.same({ ["gx"] = fn }, config.get_user_mappings("status"))
    end)
  end)

  describe("reversed mappings", function()
    it("map commands to their keys", function()
      config.setup {}
      local maps = config.get_reversed_status_maps()

      assert.are.same({ "s" }, maps["Stage"])
      table.sort(maps["Toggle"])
      assert.are.same({ "<tab>", "za" }, maps["Toggle"])
      assert.are.same({ "c" }, config.get_reversed_popup_maps()["CommitPopup"])
      assert.are.same({ "<c-c><c-c>" }, config.get_reversed_commit_editor_maps()["Submit"])
      assert.are.same({ "a" }, config.get_reversed_commit_view_maps()["OpenFileInWorktree"])
    end)

    it("yield <nop> for commands without a key", function()
      config.setup { mappings = { status = { ["s"] = false } } }

      assert.are.same("<nop>", config.get_reversed_status_maps()["Stage"])
      assert.are.same("<nop>", config.get_reversed_status_maps()["NoSuchCommand"])
    end)

    it("follow a changed configuration", function()
      config.setup {}
      assert.are.same({ "s" }, config.get_reversed_status_maps()["Stage"])

      config.values = config.get_default_values()
      config.setup { mappings = { status = { ["s"] = false, ["gs"] = "Stage" } } }

      assert.are.same({ "gs" }, config.get_reversed_status_maps()["Stage"])
    end)
  end)
end)
