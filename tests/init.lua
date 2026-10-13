-- Entry point of `make test`: runs the specs with plenary's busted runner.
-- Every spec file runs in a Neovim instance of its own, started with tests/minimal_init.lua.

local plenary_dir = os.getenv("PLENARY_DIR")
if not plenary_dir or plenary_dir == "" or not vim.uv.fs_stat(plenary_dir) then
  io.stderr:write(
    ("plenary.nvim not found at %q. Run `make test PLENARY_DIR=/path/to/plenary.nvim`.\n"):format(
      tostring(plenary_dir)
    )
  )
  vim.cmd("cquit 1")
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(plenary_dir)

vim.cmd([[runtime! plugin/plenary.vim]])

local test_files = os.getenv("TEST_FILES")
local directory = (test_files == nil or test_files == "") and "tests/specs" or test_files

require("plenary.test_harness").test_directory(directory, {
  minimal_init = "tests/minimal_init.lua",
  sequential = true,
  -- Milliseconds a spec file may take. Specs run real svn commands, which is not instant.
  timeout = 300000,
})
