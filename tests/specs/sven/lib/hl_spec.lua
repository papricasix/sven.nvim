local hl = require("sven.lib.hl")
local config = require("sven.config")

---@param name string
---@return table
local function get(name)
  return vim.api.nvim_get_hl(0, { name = name, create = false })
end

describe("lib.hl", function()
  before_each(function()
    config.values = config.get_default_values()

    -- Like a colorscheme does. Removes every group a spec defined (none of them is a default).
    vim.cmd("hi clear")
  end)

  it("defines the groups the UI uses", function()
    hl.setup(config.values)

    for _, group in ipairs {
      "SvenDiffAdd",
      "SvenDiffDelete",
      "SvenDiffContext",
      "SvenHunkHeader",
      "SvenDiffHeader",
      "SvenSectionHeader",
      "SvenPopupSectionTitle",
      "SvenPopupSwitchKey",
      "SvenPopupActionKey",
      "SvenChangeModified",
      "SvenChangeAdded",
      "SvenChangeDeleted",
      "SvenObjectId",
      "SvenGraphAuthor",
      "SvenCommandCodeError",
    } do
      assert.is_false(vim.tbl_isempty(get(group)), group)
    end
  end)

  it("derives colors from the palette when Neogit's groups do not exist", function()
    hl.setup(config.values)

    local add = get("SvenDiffAdd")
    assert.is_nil(add.link)
    assert.is_number(add.fg)
    assert.is_number(add.bg)
  end)

  it("links to the Neogit group when that exists", function()
    vim.api.nvim_set_hl(0, "NeogitDiffAdd", { fg = "#00ff00" })
    vim.api.nvim_set_hl(0, "NeogitChangeModified", { link = "Identifier" })

    hl.setup(config.values)

    assert.are.same("NeogitDiffAdd", get("SvenDiffAdd").link)
    assert.are.same("NeogitChangeModified", get("SvenChangeModified").link)
    -- No Neogit counterpart was defined for this one
    assert.is_nil(get("SvenDiffDelete").link)
  end)

  it("leaves groups alone that the user or a colorscheme defined", function()
    vim.api.nvim_set_hl(0, "SvenDiffDelete", { fg = "#123456" })
    vim.api.nvim_set_hl(0, "NeogitDiffDelete", { fg = "#ff0000" })

    hl.setup(config.values)

    assert.are.same({ fg = 0x123456 }, get("SvenDiffDelete"))
  end)

  it("defines the groups that only exist for svn", function()
    hl.setup(config.values)

    assert.are.same("SvenChangeDeleted", get("SvenChangeMissing").link)
    assert.are.same("SvenChangeUnmerged", get("SvenChangeConflicted").link)
    assert.are.same("SvenChangeRenamed", get("SvenChangeReplaced").link)
    assert.are.same("SvenUnmergedchanges", get("SvenConflicts").link)
    assert.are.same("SvenUntrackedfiles", get("SvenUnversionedfiles").link)
    assert.are.same("SvenUnstagedchanges", get("SvenChanges").link)
    assert.are.same("SvenSectionHeader", get("SvenChangelist").link)
    assert.are.same("SvenObjectId", get("SvenBlameRevision").link)
  end)

  it("has a group for every status", function()
    hl.setup(config.values)

    for _, status in ipairs {
      "modified",
      "added",
      "deleted",
      "replaced",
      "missing",
      "conflicted",
      "obstructed",
      "incomplete",
      "external",
      "ignored",
    } do
      local group = "SvenChange" .. status:sub(1, 1):upper() .. status:sub(2)
      assert.is_false(vim.tbl_isempty(get(group)), group)
    end
  end)

  it("maps a sven group to its Neogit counterpart", function()
    assert.are.same("NeogitDiffAdd", hl.neogit_group("SvenDiffAdd"))
    assert.are.same("NeogitPopupSwitchKey", hl.neogit_group("SvenPopupSwitchKey"))
  end)

  describe("when evaluated again", function()
    it("picks up a Neogit group that appeared", function()
      hl.setup(config.values)
      assert.is_nil(get("SvenHunkHeader").link)

      vim.api.nvim_set_hl(0, "NeogitHunkHeader", { fg = "#abcdef" })
      hl.setup(config.values)

      assert.are.same("NeogitHunkHeader", get("SvenHunkHeader").link)
    end)

    it("falls back to the palette when the Neogit group is gone", function()
      vim.api.nvim_set_hl(0, "NeogitHunkHeader", { fg = "#abcdef" })
      hl.setup(config.values)
      assert.are.same("NeogitHunkHeader", get("SvenHunkHeader").link)

      -- What a colorscheme without Neogit support does. The link of the sven group survives
      -- `hi clear` (it is a default), the Neogit group it points to does not.
      vim.cmd("hi clear")
      assert.are.same("NeogitHunkHeader", get("SvenHunkHeader").link)
      hl.setup(config.values)

      assert.is_nil(get("SvenHunkHeader").link)
      assert.is_number(get("SvenHunkHeader").bg)
    end)

    it("keeps a group the user redefined in the meantime", function()
      hl.setup(config.values)
      vim.api.nvim_set_hl(0, "SvenDiffDelete", { fg = "#123456" })
      vim.api.nvim_set_hl(0, "NeogitDiffDelete", { fg = "#ff0000" })

      hl.setup(config.values)

      assert.are.same({ fg = 0x123456 }, get("SvenDiffDelete"))
    end)

    it("happens on ColorScheme", function()
      require("sven").setup { remember_settings = false, filewatcher = { enabled = false } }
      hl.setup(config.values)
      assert.is_nil(get("SvenHunkHeader").link)

      vim.api.nvim_set_hl(0, "NeogitHunkHeader", { fg = "#abcdef" })
      vim.api.nvim_exec_autocmds("ColorScheme", {})

      -- It is scheduled, so that Neogit can define its groups first
      assert.is_true(vim.wait(1000, function()
        return get("SvenHunkHeader").link == "NeogitHunkHeader"
      end, 10))
    end)

    it("uses the colors of the config", function()
      config.values.highlight = { green = "#00aa00", bg_green = "#005500", line_green = "#002200" }
      hl.setup(config.values)

      assert.are.same(0x005500, get("SvenDiffAdd").fg)
      assert.are.same(0x002200, get("SvenDiffAdd").bg)
      assert.are.same(0x00aa00, get("SvenDiffAddHighlight").fg)
    end)
  end)
end)
