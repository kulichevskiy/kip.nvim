-- Minimal config used to record the demo: nvim --clean -u demo/init.lua demo/orders.py
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local data = vim.fn.stdpath("data")

vim.opt.rtp:prepend(root)
-- Optional niceties, picked up from a LazyVim install when present.
for _, p in ipairs({ "/site", "/lazy/tokyonight.nvim", "/lazy/nvim-treesitter/runtime", "/lazy/nvim-treesitter" }) do
  if vim.uv.fs_stat(data .. p) then
    vim.opt.rtp:append(data .. p)
  end
end

vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "no"
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.hlsearch = false
vim.o.showcmd = false
vim.o.ruler = false
vim.o.laststatus = 0
vim.o.scrolloff = 3
vim.o.linebreak = true
vim.o.shortmess = vim.o.shortmess .. "IS"
vim.o.fillchars = "eob: "

if not pcall(vim.cmd.colorscheme, "tokyonight-night") then
  vim.cmd.colorscheme("habamax")
end
vim.api.nvim_create_autocmd("FileType", {
  callback = function(ev)
    pcall(vim.treesitter.start, ev.buf)
  end,
})

require("kip").setup({})
