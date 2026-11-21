--- Read-only dependency diagnostics; never creates sessions or changes bindings.
---@class aviary.pigeon.health
---@field check fun()
local M = {}
local Backends = require("aviary.pigeon.backends")
local Config = require("aviary.pigeon.config")

function M.check()
  vim.health.start("aviary.pigeon")
  Backends.checkhealth(Config().backend)
  for _, name in ipairs(vim.fn.sort(vim.tbl_keys(Config().tools))) do
    local command = Config().tools[name].command[1]
    local report = vim.fn.executable(command) == 1 and vim.health.ok or vim.health.info
    report(("tool %s: %s"):format(name, command))
  end
end

return M
