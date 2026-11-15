---@module 'luassert'

local transaction = require("aviary.shared.transaction")

describe("aviary.shared.transaction", function()
  it("commits acquired resources and registered effects without running cleanup", function()
    local resource = {}
    local state = "before"
    local released = false
    local result = transaction(function(txn)
      txn:on_rollback(function()
        state = "before"
      end)
      state = "after"
      return txn:acquire(function()
        return resource
      end, function()
        released = true
      end)
    end)
    assert.are.equal(resource, result)
    assert.are.equal("after", state)
    assert.is_false(released)
  end)

  it("commits nil and false results without treating them as failures", function()
    local cleanups = 0
    local function commit(value)
      return transaction(function(txn)
        return txn:acquire(function()
          return value
        end, function()
          cleanups = cleanups + 1
        end)
      end)
    end
    assert.is_nil(commit(nil))
    assert.is_false(commit(false))
    assert.are.equal(0, cleanups)
  end)

  it("rolls back acquisitions and effects in reverse registration order", function()
    local events = {}
    local first, second, cause = {}, {}, {}
    local state = "before"
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:acquire(function()
          return first
        end, function(resource)
          assert.are.equal(first, resource)
          events[#events + 1] = "first"
        end)
        txn:on_rollback(function()
          state = "before"
          events[#events + 1] = "restore"
        end)
        state = "after"
        txn:acquire(function()
          return second
        end, function(resource)
          assert.are.equal(second, resource)
          events[#events + 1] = "second"
        end)
        error(cause, 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(cause, reason)
    assert.are.same({ "second", "restore", "first" }, events)
    assert.are.equal("before", state)
  end)

  it("passes nil and false acquisition results to rollback unchanged", function()
    local received = {}
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:acquire(function()
          return nil
        end, function(resource)
          received[#received + 1] = { value = resource }
        end)
        txn:acquire(function()
          return false
        end, function(resource)
          received[#received + 1] = { value = resource }
        end)
        error("failed", 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal("failed", reason)
    assert.are.equal(2, #received)
    assert.is_false(received[1].value)
    assert.is_nil(received[2].value)
  end)

  it("normalizes nil errors and preserves other errors after cleanup", function()
    local cause = {}
    ---@type { error: any, expected: any }[]
    local cases = {
      { error = "failed", expected = "failed" },
      { error = cause, expected = cause },
      { error = false, expected = false },
      { error = nil, expected = "error raised without a value" },
    }
    for _, case in ipairs(cases) do
      local cleaned = false
      local ok, reason = pcall(function()
        transaction(function(txn)
          txn:on_rollback(function()
            cleaned = true
          end)
          error(case.error, 0)
        end)
      end)
      assert.is_false(ok)
      assert.are.equal(case.expected, reason)
      assert.is_true(cleaned)
    end
  end)

  it("propagates failure before any rollback has been registered", function()
    local cause = {}
    local ok, reason = pcall(function()
      transaction(function()
        error(cause, 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(cause, reason)
  end)

  it("composes an atomic factory with its own transaction and unwinds earlier acquisitions", function()
    local events = {}
    local cause = {}
    local completed = false
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:acquire(function()
          return "outer"
        end, function(resource)
          events[#events + 1] = resource
        end)
        txn:acquire(function()
          return transaction(function(inner)
            inner:acquire(function()
              return "inner"
            end, function(resource)
              events[#events + 1] = resource
            end)
            error(cause, 0)
          end)
        end, function()
          events[#events + 1] = "factory result"
        end)
        completed = true
        return completed
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(cause, reason)
    assert.are.same({ "inner", "outer" }, events)
    assert.is_false(completed)
  end)

  it("attempts every rollback and retains all errors before formatting them", function()
    local events = {}
    local formatted = 0
    local cause = setmetatable({}, {
      __tostring = function()
        formatted = formatted + 1
        return "creation failed"
      end,
    })
    local oldest_failure = setmetatable({}, {
      __tostring = function()
        return "oldest cleanup failed"
      end,
    })
    local newest_failure = "newest cleanup failed"
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:on_rollback(function()
          events[#events + 1] = "oldest"
          error(oldest_failure, 0)
        end)
        txn:on_rollback(function()
          events[#events + 1] = "middle"
        end)
        txn:on_rollback(function()
          events[#events + 1] = "newest"
          error(newest_failure, 0)
        end)
        error(cause, 0)
      end)
    end)
    assert.is_false(ok)
    ---@cast reason aviary.shared.transaction.Error
    assert.are.same({ "newest", "middle", "oldest" }, events)
    local errors = rawget(reason, "errors")
    assert.are.equal(cause, rawget(reason, "cause"))
    assert.are.equal(2, #errors)
    assert.are.equal(newest_failure, errors[1])
    assert.are.equal(oldest_failure, errors[2])
    assert.are.equal(0, formatted)
    assert.are.equal(
      "creation failed\nrollback also failed:\n  1. newest cleanup failed\n  2. oldest cleanup failed",
      tostring(reason)
    )
    assert.are.equal(1, formatted)
  end)

  it("normalizes nil errors and preserves false errors in composites", function()
    ---@type { error: any, expected: any }[]
    local cases = {
      { error = nil, expected = "error raised without a value" },
      { error = false, expected = false },
    }
    for _, case in ipairs(cases) do
      local ok, reason = pcall(function()
        transaction(function(txn)
          txn:on_rollback(function()
            error(nil, 0)
          end)
          txn:on_rollback(function()
            error(false, 0)
          end)
          error(case.error, 0)
        end)
      end)
      assert.is_false(ok)
      ---@cast reason aviary.shared.transaction.Error
      local errors = rawget(reason, "errors")
      assert.are.equal(case.expected, rawget(reason, "cause"))
      assert.are.equal(2, #errors)
      assert.is_false(errors[1])
      assert.are.equal("error raised without a value", errors[2])
      assert.are.equal(
        tostring(case.expected) .. "\nrollback also failed:\n  1. false\n  2. error raised without a value",
        tostring(reason)
      )
    end
  end)
end)
