---@module 'luassert'

local protect = require("aviary.shared.protect")

describe("aviary.shared.protect", function()
  local original_notify, notifications

  before_each(function()
    original_notify, notifications = vim.notify, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("defers execution and preserves nil arguments and an empty result list", function()
    local received
    local call = protect(function(...)
      received = vim.F.pack_len(...)
    end)
    assert.is_nil(received)
    assert.are.same({ true, n = 1 }, vim.F.pack_len(call("first", nil, "third", nil)))
    assert.are.same({ "first", nil, "third", n = 4 }, received)
    assert.are.same({}, notifications)
  end)

  it("distinguishes successful nil/false results and preserves trailing nils", function()
    local call = protect(function()
      return nil, false, "value", nil
    end)
    assert.are.same({ true, nil, false, "value", n = 5 }, vim.F.pack_len(call()))
    assert.are.same({}, notifications)
  end)

  it("does not report normal nil/reason returns as exceptions", function()
    local call = protect(function()
      return nil, "ordinary result"
    end)
    assert.are.same({ true, nil, "ordinary result", n = 3 }, vim.F.pack_len(call()))
    assert.are.same({}, notifications)
  end)

  it("warns once with the stringified error and returns the original object", function()
    local reason = setmetatable({}, {
      __tostring = function()
        return "operation failed"
      end,
    })
    local call = protect(function()
      error(reason, 0)
    end)
    local result = vim.F.pack_len(call())
    assert.are.equal(2, result.n)
    assert.is_false(result[1])
    assert.is_true(rawequal(reason, result[2]))
    assert.are.same({ { "operation failed", vim.log.levels.WARN } }, notifications)
  end)

  for _, fixture in ipairs({ { name = "nil" }, { name = "false", reason = false } }) do
    it("preserves an error whose value is " .. fixture.name, function()
      local call = protect(function()
        error(fixture.reason, 0)
      end)
      assert.are.same({ false, fixture.reason, n = 2 }, vim.F.pack_len(call()))
      assert.are.same({ { fixture.name, vim.log.levels.WARN } }, notifications)
    end)
  end

  it("never retries failed calls", function()
    local calls = 0
    local call = protect(function()
      calls = calls + 1
      error("operation failed", 0)
    end)
    assert.are.same({ false, "operation failed" }, { call() })
    assert.are.equal(1, calls)
    assert.are.same({ { "operation failed", vim.log.levels.WARN } }, notifications)
  end)

  it("propagates notification exceptions without notifying again", function()
    local calls = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function()
      calls = calls + 1
      error("notification failed", 0)
    end
    local call = protect(function()
      error("operation failed", 0)
    end)
    assert.has_error(call, "notification failed")
    assert.are.equal(1, calls)
  end)
end)
