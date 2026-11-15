--- :checkhealth aviary.hawk
local M = {}

function M.check()
  vim.health.start("aviary.hawk")
  if vim.fn.executable("git") == 0 then
    vim.health.warn("Git is required for Review")
  else
    vim.health.ok("git: " .. vim.trim(vim.fn.system({ "git", "--version" })))
  end
end

return M
