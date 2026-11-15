---@module 'luassert'

local Helpers = require("weaver.helpers")
local format = Helpers.format

describe("aviary.weaver references", function()
  local Config, Weaver
  local original_picker
  local chosen, submitted
  local restore_delivery

  --- Confirm paths through the flow and capture its Message.
  ---@param flow fun()
  ---@param paths string[]
  ---@return aviary.shared.Message
  local function choose(flow, paths)
    chosen = paths
    flow()
    return assert(submitted)
  end

  before_each(function()
    restore_delivery = Helpers.delivery(function(message)
      submitted = message
    end)
    Helpers.reload_weaver()
    Config = require("aviary.weaver.config")
    original_picker = package.loaded["aviary.weaver.picker"]
    chosen, submitted = nil, nil
    local function confirm(_source, on_confirm)
      on_confirm(chosen)
    end
    package.loaded["aviary.weaver.picker"] = { pick = confirm }
    Weaver = require("aviary").weaver
    Config.setup()
  end)

  after_each(function()
    restore_delivery()
    package.loaded["aviary.weaver.picker"] = original_picker
    Helpers.reload_weaver()
  end)

  it("joins the chosen references for the target's own cwd", function()
    local message = choose(Weaver.files, { "/tmp/proj/a.lua", "/tmp/proj/sub/b.lua" })
    assert.are.equal("a.lua\nsub/b.lua", (message:eval({ cwd = "/tmp/proj", format = format })))
    assert.are.equal("/tmp/proj/a.lua\n/tmp/proj/sub/b.lua", (message:eval({ format = format })))
  end)

  it("honours the configured separator", function()
    Config.setup({ references = { join = " " } })
    local paths = { "/tmp/p/a.lua", "/tmp/p/b.lua" }
    local message = choose(Weaver.buffers, paths)
    paths[1] = "/tmp/p/changed.lua"
    Config.setup({ references = { join = ", " } })
    assert.are.equal("a.lua b.lua", (message:eval({ cwd = "/tmp/p", format = format })))
  end)

  it("declines the whole message when a reference is declined", function()
    Config.setup({ references = { join = " " } })
    local rendered, why = choose(Weaver.files, { "/tmp/p/a.lua", "/tmp/p/b.lua" }):eval({
      cwd = "/tmp/p",
      format = function(file)
        if file ~= "b.lua" then
          return file
        end
      end,
    })
    assert.is_nil(rendered)
    assert.is_truthy(assert(why):find("b.lua", 1, true))
  end)
end)
