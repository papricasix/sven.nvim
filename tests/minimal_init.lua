-- Init file of the Neovim instance each spec file runs in.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local plenary_dir = os.getenv("PLENARY_DIR")
if plenary_dir and plenary_dir ~= "" then
  vim.opt.runtimepath:prepend(plenary_dir)
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

vim.cmd("runtime plugin/sven.lua")
