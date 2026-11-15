---@module 'luassert'

local config = require("aviary.hawk.config")

describe("Hawk Review options", function()
  after_each(function()
    config.setup()
  end)

  it("replaces key sets including empty sets and preserves other defaults", function()
    assert.is_true(config.setup({ keymaps = { close = {}, jump = { "o" } } }))
    assert.are.same({}, config().keymaps.close)
    assert.are.same({ "o" }, config().keymaps.jump)
    assert.are.same({ "b" }, config().keymaps.base_ref)
    config.setup()
    assert.are.same({ "q" }, config().keymaps.close)
  end)

  it("rejects unknown options and invalid shapes without changing the current config", function()
    config.setup({ keymaps = { jump = { "o" } } })
    local before, saved = config(), vim.deepcopy(config())
    for _, case in ipairs({
      { options = { keympas = {} }, reason = "unknown option keympas" },
      { options = { keymaps = false }, reason = "keymaps and actions must be tables" },
      { options = { keymaps = { jump = "o" } }, reason = "keymaps must map actions to lists of keys" },
      { options = { actions = { bad = true } }, reason = "actions must map names to functions" },
    }) do
      local ok, message = config.setup(case.options)
      assert.is_false(ok)
      assert.are.equal("hawk: " .. case.reason, message)
      assert.are.equal(before, config())
      assert.are.same(saved, config())
    end
  end)

  it("requires a handler for every mapped action", function()
    for action in pairs(config().keymaps) do
      assert.is_function(config().actions[action])
    end
    local ok, reason = config.setup({ keymaps = { missing_handler = { "<Tab>" } } })
    assert.is_false(ok)
    assert.matches("no handler for missing_handler", assert(reason))
  end)

  it("accepts custom actions alongside built-ins", function()
    local inspect = function() end
    assert.is_true(config.setup({ keymaps = { inspect = { "i", "I" } }, actions = { inspect = inspect } }))
    assert.are.equal(inspect, config().actions.inspect)
    assert.are.same({ "i", "I" }, config().keymaps.inspect)
    assert.are.same({ "q" }, config().keymaps.close)
  end)

  it("dispatches jumps to the current original item", function()
    local selected, calls = {}, 0
    ---@type any minimal action receiver
    local tab = {
      current = function()
        return nil
      end,
    }
    config().actions.jump(tab)
    tab.current = function()
      return selected
    end
    tab.jump = function(_, item)
      assert.are.equal(selected, item)
      calls = calls + 1
    end
    config().actions.jump(tab)
    assert.are.equal(1, calls)
  end)
end)
