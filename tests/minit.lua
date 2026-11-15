#!/usr/bin/env -S nvim -l

-- Install isolated dependencies under .tests/ and run mini.test specs.
vim.env.LAZY_STDPATH = ".tests"

vim.cmd("filetype plugin on")

-- Reuse a local lazy.nvim checkout so bootstrap can run offline.
local lazy_candidates = {
  vim.fn.fnamemodify("~/.local/share/nvim/lazy/lazy.nvim", ":p"),
  vim.fn.fnamemodify("~/.local/share/nvim/site/pack/lazy/start/lazy.nvim", ":p"),
  vim.fn.fnamemodify("~/projects/lazy.nvim", ":p"),
}
if vim.env.LAZY_PATH and vim.env.LAZY_PATH ~= "" then
  table.insert(lazy_candidates, 1, vim.env.LAZY_PATH)
end
local lazy_path
for _, path in ipairs(lazy_candidates) do
  if path and path ~= "" and vim.fn.isdirectory(path) == 1 then
    lazy_path = path
    break
  end
end

vim.env.LAZY_PATH = lazy_path
if lazy_path then
  loadfile(vim.fs.joinpath(lazy_path, "bootstrap.lua"))()
else
  load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"), "bootstrap.lua")()
end

require("lazy.minit").setup({
  spec = {
    { dir = vim.uv.cwd() },
  },
})
