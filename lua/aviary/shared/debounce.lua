--- Trailing-edge debounce with main-loop delivery. reset(ms) replaces the pending
--- call, including delivery already queued by the timer. close() releases the timer
--- and callback; later reset/close calls do nothing. Callback errors propagate.
---
--- ```lua
--- local debounce = require("aviary.shared.debounce").new(refresh)
--- debounce:reset(100)
--- debounce:close()
--- ```
---@class aviary.shared.Debounce
---@field package _timer? uv.uv_timer_t owned timer; nil after close
---@field package _callback? fun() borrowed until close; nil after close
---@field package _generation integer changes on reset to invalidate queued delivery
---@field package _on_timer fun() reusable native callback
local M = {}
M.__index = M

--- Allocate an idle debounce. Timer acquisition failure raises.
---@param callback fun() called on the main loop; must not yield
---@return aviary.shared.Debounce
function M.new(callback)
  local timer = assert(vim.uv.new_timer())
  ---@type aviary.shared.Debounce
  local self
  local function on_timer()
    local generation = self._generation
    vim.schedule(function()
      local pending = self._callback
      if pending and self._generation == generation then
        pending()
      end
    end)
  end
  self = setmetatable({ _timer = timer, _callback = callback, _generation = 0, _on_timer = on_timer }, M)
  return self
end

--- Restart the one-shot delay. Safe from fast events; no editor APIs are used.
---@param ms integer nonnegative delay in milliseconds
---@return nil
function M:reset(ms)
  local timer = self._timer
  if not timer then
    return
  end
  self._generation = self._generation + 1
  timer:start(ms, 0, self._on_timer)
end

--- Idempotently suppress delivery, release the callback and close the timer.
---@return nil
function M:close()
  local timer = self._timer
  if not timer then
    return
  end
  self._timer = nil
  self._callback = nil
  timer:stop()
  timer:close()
end

return M
