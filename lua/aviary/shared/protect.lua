---@param ok boolean
---@param ... any original results or error
---@return boolean ok
---@return any ... original results or error
local function report(ok, ...)
  if not ok then
    require("aviary.shared.notify").warn(tostring((...)))
  end
  return ok, ...
end

--- Build a protected callable without executing it. The wrapper borrows fn for
--- its lifetime and forwards arguments unchanged. Success returns true followed
--- by all original results, including nils and their exact count. Failure reports
--- tostring(error) once through shared notify.warn, then returns false and the
--- original error, including nil/false. Normal nil/error results remain successes.
--- Only the wrapped call is protected: notification errors propagate. There is no
--- scheduling, retry or later-callback protection; callers leave fast events first.
--- Callers own business recovery.
---@param fn function
---@return function wrapped returns a success flag followed by the original results or error
local function protect(fn)
  return function(...)
    return report(pcall(fn, ...))
  end
end

return protect
