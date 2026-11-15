---@class aviary.pigeon.TestHelpers
---@field reload_pigeon fun()
---@field notifications fun(fn: fun()): string[]
---@field targets fun(backend: aviary.pigeon.backends.tmux): aviary.pigeon.TmuxTarget[]
---@field create fun(backend: aviary.pigeon.backends.tmux, name: string): aviary.pigeon.TmuxTarget
local M = {}

function M.reload_pigeon()
  for name in pairs(package.loaded) do
    if name == "aviary.pigeon" or name:find("^aviary%.pigeon%.") then
      package.loaded[name] = nil
    end
  end
  local aviary = package.loaded["aviary"]
  if aviary then
    aviary.pigeon = nil
  end
end

function M.notifications(fn)
  local seen, saved = {}, vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(message)
    seen[#seen + 1] = message
  end
  local ok, reason = pcall(fn)
  vim.notify = saved
  assert(ok, reason)
  return seen
end

function M.targets(backend)
  local result = {}
  for _, candidate in ipairs(backend.list()) do
    if tostring(candidate):sub(1, #" ") == " " then
      result[#result + 1] = candidate:resolve()
    end
  end
  return result
end

function M.create(backend, name)
  for _, candidate in ipairs(backend.list()) do
    if tostring(candidate) == " " .. name then
      return candidate:resolve()
    end
  end
  error("missing tool choice: " .. name, 0)
end

return M
