--- Read-only tmux diagnostics for the tmux backend.
---@class aviary.pigeon.tmux.health
---@field check fun()
local M = {}
local Process = require("aviary.shared.process")

function M.check()
  if vim.fn.executable("tmux") ~= 1 then
    vim.health.error("tmux executable is unavailable")
  else
    local result = Process.run({ "tmux", "-V" })
    local major, minor = result.stdout:match("(%d+)%.(%d+)")
    if result.code ~= 0 or not major then
      vim.health.error("could not read tmux version: " .. vim.trim(result.stderr))
    elseif tonumber(major) < 3 or (tonumber(major) == 3 and tonumber(minor) < 8) then
      vim.health.error("tmux 3.8+ is required")
    else
      vim.health.ok("tmux: " .. vim.trim(result.stdout))
    end
  end
  if not vim.env.TMUX then
    vim.health.error("TMUX not set; run Neovim inside tmux")
  else
    vim.health.ok("tmux host context: available")
  end
end

return M
