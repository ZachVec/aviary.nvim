---@module 'luassert'

local Debounce = require("aviary.shared.debounce")

local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(
    vim.wait(1000, function()
      return done
    end),
    "scheduled callback did not run"
  )
end

--- Control native firing independently from queued main-loop delivery.
local function with_timer(work)
  local saved = vim.uv.new_timer
  ---@type any
  local timer = { starts = {}, stops = 0, closes = 0 }
  function timer:start(ms, repeat_ms, callback)
    self.starts[#self.starts + 1] = { ms = ms, repeat_ms = repeat_ms, callback = callback }
  end
  function timer:stop()
    self.stops = self.stops + 1
  end
  function timer:close()
    self.closes = self.closes + 1
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.uv.new_timer = function()
    return timer
  end
  local ok, reason = pcall(work, timer)
  vim.uv.new_timer = saved
  assert(ok, reason)
end

describe("aviary.shared.debounce", function()
  it("coalesces a burst and delivers once outside fast events", function()
    local calls, fast = 0, nil
    local debounce = Debounce.new(function()
      calls, fast = calls + 1, vim.in_fast_event()
    end)
    debounce:reset(0)
    debounce:reset(0)
    debounce:reset(0)
    local fired = vim.wait(1000, function()
      return calls > 0
    end)
    debounce:close()
    flush()
    assert.is_true(fired)
    assert.are.equal(1, calls)
    assert.is_false(fast)
  end)

  it("invalidates delivery already queued before a later reset", function()
    with_timer(function(timer)
      local calls = 0
      local debounce = Debounce.new(function()
        calls = calls + 1
      end)
      debounce:reset(10)
      timer.starts[1].callback()
      debounce:reset(20)
      flush()
      assert.are.equal(0, calls)
      assert.are.equal(10, timer.starts[1].ms)
      assert.are.equal(20, timer.starts[2].ms)
      assert.are.equal(0, timer.starts[2].repeat_ms)
      timer.starts[2].callback()
      flush()
      assert.are.equal(1, calls)
      debounce:close()
    end)
  end)

  it("suppresses queued delivery and releases resources once after close", function()
    with_timer(function(timer)
      local calls = 0
      local debounce = Debounce.new(function()
        calls = calls + 1
      end)
      debounce:reset(0)
      timer.starts[1].callback()
      debounce:close()
      debounce:close()
      debounce:reset(0)
      flush()
      assert.are.equal(0, calls)
      assert.are.equal(1, #timer.starts)
      assert.are.equal(1, timer.stops)
      assert.are.equal(1, timer.closes)
    end)
  end)

  it("releases the callback's captured state while the closed debounce stays live", function()
    with_timer(function()
      local weak = setmetatable({}, { __mode = "v" })
      local function callback()
        local payload = { "owner" }
        weak[1] = payload
        return function()
          assert.are.equal("owner", payload[1])
        end
      end
      local debounce = Debounce.new(callback())
      collectgarbage("collect")
      assert.is_not_nil(weak[1])
      debounce:close()
      collectgarbage("collect")
      collectgarbage("collect")
      assert.is_nil(weak[1])
      debounce:close()
    end)
  end)
end)
