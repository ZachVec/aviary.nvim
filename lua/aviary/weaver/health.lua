--- :checkhealth aviary.weaver
local M = {}

local start = vim.health.start
local ok = vim.health.ok
local err = vim.health.error

function M.check()
  start("aviary.weaver")

  if vim.fn.has("nvim-0.11") == 1 then
    ok("Neovim >= 0.11")
  else
    err("Neovim >= 0.11 is required")
    return
  end

  vim.health.ok("picker: " .. require("aviary.weaver.config")().picker)

  local prompts = require("aviary.weaver.config")().prompts
  ok(("prompts: %d"):format(vim.tbl_count(prompts)))
end

return M
