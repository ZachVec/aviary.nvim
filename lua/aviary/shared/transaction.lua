--- Synchronous resource acquisition with rollback on failure.
--- Normal return means success; an exception means failure. Success retains all
--- effects and transfers responsibility for acquired resources to the caller.
--- Failure attempts every rollback in reverse registration order, then rethrows
--- the original error or an Error containing it and all rollback failures.
--- Nil errors become "error raised without a value"; other errors stay unchanged.
---
--- fn, factories and rollback actions must complete synchronously. A transaction is
--- borrowed only during fn and must not escape it. Factories are failure-atomic:
--- an exception leaves no acquired resources or state changes behind.
---
--- ```lua
--- local transaction = require("aviary.shared.transaction")
--- local resource = transaction(function(txn)
---   return txn:acquire(create_resource, release_resource)
--- end)
--- ```

---@class aviary.shared.Transaction
---@field public on_rollback fun(self: self, rollback: fun()) register an action for failure only
---@field public acquire fun<T>(self: self, factory: (fun(): T), rollback: fun(resource: T)): T acquire and register cleanup after successful return
---@field private _rollbacks (fun())[]
local Transaction = {}

--- Collects a failed transaction's cause and rollback errors. raise throws this
--- object only when rollback also failed; otherwise it rethrows the normalized cause.
---@class aviary.shared.transaction.Error
---@field package cause any original transaction error; normalized by raise
---@field package errors any[] rollback errors in execution order
---@field package raise fun(self: self) normalize cause and throw this object or cause according to rollback errors
---@field private __tostring fun(self: self): string format the composite failure
local Error = {}

---@generic T
---@param fn fun(txn: aviary.shared.Transaction): T
---@return T result fn's first result on success
local function transaction(fn)
  local rollbacks = {}
  local txn = setmetatable({ _rollbacks = rollbacks }, Transaction)
  local ok, result = pcall(fn, txn)
  if not ok then
    local err = setmetatable({ cause = result, errors = {} }, Error)
    for index = #rollbacks, 1, -1 do
      local rolled_back, reason = pcall(rollbacks[index])
      if not rolled_back then
        if reason == nil then
          reason = "error raised without a value"
        end
        err.errors[#err.errors + 1] = reason
      end
    end
    err:raise()
  end
  return result
end

Transaction.__index = Transaction
Error.__index = Error

function Transaction:on_rollback(rollback)
  local rollbacks = self._rollbacks
  rollbacks[#rollbacks + 1] = rollback
end

function Transaction:acquire(factory, rollback)
  local resource = factory()
  self:on_rollback(function()
    rollback(resource)
  end)
  return resource
end

function Error:raise()
  if self.cause == nil then
    self.cause = "error raised without a value"
  end
  if #self.errors > 0 then
    error(self, 0)
  end
  error(self.cause, 0)
end

function Error:__tostring()
  local lines = { tostring(self.cause), "rollback also failed:" }
  for index, failure in ipairs(self.errors) do
    lines[#lines + 1] = ("  %d. %s"):format(index, tostring(failure))
  end
  return table.concat(lines, "\n")
end

return transaction
