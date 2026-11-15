---@module 'luassert'

local Helpers = require("weaver.helpers")

describe("aviary.weaver", function()
  local restore_delivery

  setup(function()
    Helpers.reload_weaver()
  end)

  teardown(function()
    Helpers.reload_weaver()
    pcall(vim.api.nvim_del_user_command, "Weaver")
  end)

  before_each(function()
    restore_delivery = Helpers.delivery(function() end)
  end)

  after_each(function()
    restore_delivery()
  end)

  it("exposes the flows as Lua calls", function()
    local weaver = require("aviary").weaver
    assert.are.equal("function", type(weaver.setup))
    for _, name in ipairs({ "prompt", "files", "buffers", "text" }) do
      assert.are.equal("function", type(weaver[name]))
    end
    assert.is_true(weaver.setup({}))
  end)

  it("merges the caller's options into the config module", function()
    require("aviary").weaver.setup({ references = { join = " " } })
    assert.are.equal(" ", require("aviary.weaver.config")().references.join)
  end)

  it("updates template configuration without notifying", function()
    local notes = Helpers.notifications(function()
      assert.is_true(require("aviary").weaver.setup({ prompts = { bad = "hello {nope}" } }))
    end)
    assert.are.same({}, notes)
  end)

  it("returns invalid configuration without notifying", function()
    local notes = Helpers.notifications(function()
      ---@diagnostic disable-next-line: assign-type-mismatch
      local ok, message = require("aviary").weaver.setup({ prompts = { bad = 42 } })
      assert.is_false(ok)
      assert.is_truthy(assert(message):find("bad", 1, true))
    end)
    assert.are.same({}, notes)
  end)

  it("installs no user command", function()
    require("aviary").weaver.setup({})
    assert.are.equal(0, vim.fn.exists(":Weaver"))
  end)

  it("propagates delivery callback errors without calling it twice", function()
    local calls = 0
    require("aviary").pigeon.send = function()
      calls = calls + 1
      error("text callback failed", 0)
    end
    assert.has_error(function()
      require("aviary").weaver.text()
    end, "text callback failed")
    assert.are.equal(1, calls)
  end)
end)
