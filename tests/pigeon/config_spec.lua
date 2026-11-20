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
    assert.is_true(Config.setup({
      format = format,
      tools = { codex = { command = { "my-codex" } }, other = { command = { "other", ";" } } },
      keymaps = { close = { "q" }, prompt = { "<C-p>" } },
      actions = { close = close, prompt = prompt },
      prompts = { review = "Review {file}" },
      resolvers = { custom = resolve },
      view = { width = 80 },
    }))
    assert.are.equal(format, Config().format)
    assert.is_nil(Config().tools.codex.format)
    assert.are.same({ "my-codex" }, Config().tools.codex.command)
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

  it("accepts built-in actions in keymaps and rejects actions without handlers", function()
    assert.is_true(Config.setup({ keymaps = { prompt = { "<C-p>" } } }))
    local ok, reason = Config.setup({ keymaps = { files = { "<C-f>" } } })
    assert.is_false(ok)
    assert.are.equal("pigeon: no handler for files", reason)
  end)

  it("accepts fractions/cells without resolving editor geometry or acquiring resources", function()
    for _, width in ipairs({ 0.01, 0.8, 1, 2, 80 }) do
      assert.is_true(Config.setup({ view = { width = width }, tools = { missing = { command = { "/missing" } } } }))
      assert.are.equal(width, Config().view.width)
    end
    assert.is_nil(package.loaded["aviary.pigeon.backends.tmux"])
    assert.is_nil(package.loaded["aviary.pigeon.backends"])
  end)

  it("rejects invalid and removed options quietly and preserves borrowed running data", function()
    Config.setup({ view = { width = 80 } })
    local borrowed, before = Config(), vim.deepcopy(Config())
    local notes = Helpers.notifications(function()
      for _, opts in ipairs({
        false,
        42,
        { format = false },
        { tools = false },
        { tools = { bad = {} } },
        { tools = { codex = { command = {} } } },
        { tools = { codex = { command = { "" } } } },
        { tools = { codex = { command = { "x", false } } } },
        { tools = { codex = { format = false } } },
        { tools = { codex = { commnad = { "x" } } } },
        { backend = "missing" },
        { backend = { default = "tmux" } },
        { view = false },
        { view = { width = "90%" } },
        { view = { width = 1.5 } },
        { view = { width = 0 } },
        { view = { height = -1 } },
        { view = { width = math.huge } },
        { view = { width = 0 / 0 } },
        { view = { close = "q" } },
        { view = { border = "invalid" } },
        { view = { widht = 42 } },
        { keymaps = false },
        { keymaps = { close = "q" } },
        { keymaps = { close = { "" } } },
        { keymaps = { close = { "q", false } } },
        { keymaps = { [1] = { "q" } } },
        { keymaps = { missing_handler = { "q" } } },
        { actions = false },
        { actions = { close = true } },
        { actions = { prompt = false } },
        { prompts = false },
        { prompts = { bad = 42 } },
        { resolvers = false },
        { resolvers = { bad = 42 } },
      }) do
        local ok, reason = Config.setup(opts)
        assert.is_false(ok)
        assert.is_truthy(reason:find("pigeon:", 1, true))
        assert.is_true(rawequal(borrowed, Config()))
        assert.are.same(before, Config())
      end
    end)
    assert.are.same({}, notes)
  end)
end)
