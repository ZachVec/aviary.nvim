---@module 'luassert'
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
describe("aviary.pigeon.config", function()
  local Config
  before_each(function()
    Helpers.reload_pigeon()
    Config = require("aviary.pigeon.config")
  end)
  after_each(Helpers.reload_pigeon)

  it("ships tools, display defaults, built-in actions, prompts and resolvers", function()
    assert.are.equal("tmux", Config().backend)
    assert.are.same({ "codex" }, Config().tools.codex.command)
    assert.are.same({ "claude" }, Config().tools.claude.command)
    assert.are.same({ width = 0.9, height = 0.9, border = "rounded" }, Config().view)
    assert.are.same({ close = { "<C-.>" } }, Config().keymaps)
    assert.is_function(Config().actions.close)
    assert.is_function(Config().actions.prompt)
    assert.is_function(Config().actions.pick)
    assert.is_function(Config().actions.buffers)
    assert.are.same({ ["{file}"] = "{file} ", ["{line}"] = "{line} " }, Config().prompts)
    assert.is_function(Config().resolvers.file)
    assert.is_function(Config().resolvers.line)
  end)

  it("merges tool/view/action/template overrides and resets omitted options to defaults", function()
    local format = function(path)
      return "!" .. path
    end
    local close = function() end
    local prompt = function() end
    local resolve = function()
      return "x"
    end
    local command = { "other", ";" }
    ---@type aviary.pigeon.ToolOverrides
    local other = { command = command }
    assert.is_true(Config.setup({
      tools = { codex = { format = format }, other = other },
      keymaps = { close = { "q" }, prompt = { "<C-p>" } },
      actions = { close = close, prompt = prompt },
      prompts = { review = "Review {file}" },
      resolvers = { custom = resolve },
      view = { width = 80 },
    }))
    assert.are.equal(format, Config().tools.codex.format)
    assert.are.same({ "codex" }, Config().tools.codex.command)
    assert.are.equal("a.lua :L7", Config().tools.other.format("a.lua", 7))
    assert.is_nil(other.format)
    command[1] = "changed"
    assert.are.same({ "other", ";" }, Config().tools.other.command)
    assert.are.equal(0.9, Config().view.height)
    assert.are.same({ "q" }, Config().keymaps.close)
    assert.are.same({ "<C-p>" }, Config().keymaps.prompt)
    assert.are.equal(close, Config().actions.close)
    assert.are.equal(prompt, Config().actions.prompt)
    assert.are.equal("Review {file}", Config().prompts.review)
    assert.are.equal(resolve, Config().resolvers.custom)
    assert.is_true(Config.setup())
    assert.is_nil(Config().tools.other)
    assert.are.same({ "<C-.>" }, Config().keymaps.close)
    assert.is_nil(Config().keymaps.prompt)
    assert.is_function(Config().actions.close)
    assert.is_function(Config().actions.prompt)
    assert.is_function(Config().actions.pick)
    assert.is_function(Config().actions.buffers)
    assert.is_nil(Config().prompts.review)
    assert.is_nil(Config().resolvers.custom)
  end)

  it("replaces key sets including empty sets and accepts custom actions", function()
    local inspect = function() end
    assert.is_true(Config.setup({
      keymaps = { close = {}, inspect = { "i", "I" } },
      actions = { inspect = inspect },
    }))
    assert.are.same({}, Config().keymaps.close)
    assert.are.same({ "i", "I" }, Config().keymaps.inspect)
    assert.are.equal(inspect, Config().actions.inspect)
    assert.is_function(Config().actions.close)
  end)

  it("accepts built-in action names in keymaps", function()
    assert.is_true(Config.setup({
      keymaps = { buffers = { "<C-b>" }, prompt = { "<C-p>" }, pick = { "<F5>" } },
    }))
    assert.are.same({ "<C-b>" }, Config().keymaps.buffers)
    assert.are.same({ "<F5>" }, Config().keymaps.pick)
  end)

  it("accepts fractions/cells without resolving editor geometry or acquiring resources", function()
    for _, width in ipairs({ 0.01, 0.8, 1, 2, 80 }) do
      assert.is_true(Config.setup({ view = { width = width }, tools = { missing = { command = { "/missing" } } } }))
      assert.are.equal(width, Config().view.width)
    end
    assert.is_nil(package.loaded["aviary.pigeon.backends.tmux"])
    assert.is_nil(package.loaded["aviary.pigeon.backends"])
  end)
end)
