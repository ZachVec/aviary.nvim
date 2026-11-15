--- Notify synchronously with the aviary title and unchanged message.
--- Callers must schedule delivery out of fast events.
---@class aviary.shared.notify
---@field info fun(msg: string) report information
---@field warn fun(msg: string) report a warning
---@field error fun(msg: string) report an error
local M = {}

function M.info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "aviary" })
end

function M.warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "aviary" })
end

function M.error(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "aviary" })
end

return M
