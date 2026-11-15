---@module 'luassert'

local Helpers = require("weaver.helpers")

describe("aviary.weaver.health", function()
  local Health
  local reports

  --- What `:checkhealth aviary.weaver` would print, as `{ level, message }` rows.
  local function report(check)
    local saved = vim.health
    local stub = {}
    reports = {}
    for _, name in ipairs({ "start", "ok", "warn", "error" }) do
      stub[name] = function(msg)
        reports[#reports + 1] = { name, msg }
      end
    end
    -- `health.lua` captures these at load time, so the stub goes in first.
    vim.health = setmetatable(stub, { __index = saved })
    Helpers.reload_weaver()
    Health = require("aviary.weaver.health")
    local ok, err = pcall(check)
    vim.health = saved
    Helpers.reload_weaver()
    assert(ok, err)
  end

  teardown(function()
    Helpers.reload_weaver()
  end)

  it("reports the version, the picker, and the prompt count", function()
    report(function()
      require("aviary").weaver.setup({ picker = "snacks" })
      Health.check()
    end)

    assert.are.same({ "start", "aviary.weaver" }, reports[1])
    assert.are.same({ "ok", "Neovim >= 0.11" }, reports[2])
    assert.are.same({ "ok", "picker: snacks" }, reports[3])
    assert.are.same({ "ok", "prompts: 2" }, reports[4])
  end)
end)
