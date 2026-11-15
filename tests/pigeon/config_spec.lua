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

  it("ships tool definitions and clipboard with floating view display defaults", function()
    assert.are.equal("clipboard", Config().backend.default)
    assert.are.same({ "codex" }, Config().tools.codex.command)
    assert.are.same({ "claude" }, Config().tools.claude.command)
    assert.are.same({ width = "90%", height = "90%", close = "C-." }, Config().backend.tmux)
  end)

  it("merges partial built-in overrides, adds tools and rebuilds from defaults", function()
    local format = function(path)
      return path
    end
    assert.is_true(Config.setup({
      tools = {
        codex = { command = { "my-codex", "--flag" }, format = format },
        ["other#"] = {
          command = { "other", ";" },
          format = function(path)
            return path
          end,
        },
      },
      backend = { default = "tmux", tmux = { width = "80" } },
    }))
    assert.are.equal("a :L2", Config().format("a", 2))
    assert.are.equal(format, Config().tools.codex.format)
    assert.are.same({ "other", ";" }, Config().tools["other#"].command)
    assert.are.equal("90%", Config().backend.tmux.height)
    assert.are.equal("80", Config().backend.tmux.width)
    Config.setup()
    assert.is_nil(Config().tools["other#"])
    assert.are.equal("clipboard", Config().backend.default)
    assert.are.same({ width = "90%", height = "90%", close = "C-." }, Config().backend.tmux)
  end)

  it("prepares close-key arguments during setup while preserving the raw key", function()
    assert.are.equal("C-.", Config.tmux_close_arg)
    for _, key in ipairs({ ";", "M-;" }) do
      local opts = { backend = { tmux = { close = key } } }
      assert.is_true(Config.setup(opts))
      assert.are.equal(key, Config().backend.tmux.close)
      assert.are.equal(key, opts.backend.tmux.close)
      assert.are.equal(key:sub(1, -2) .. "\\;", Config.tmux_close_arg)
      assert.is_true(Config.setup(opts))
      assert.are.equal(key:sub(1, -2) .. "\\;", Config.tmux_close_arg)
    end
    assert.is_false(Config.setup({ backend = { tmux = { close = "" } } }))
    assert.are.equal("M-\\;", Config.tmux_close_arg)
    assert.is_true(Config.setup())
    assert.are.equal("C-.", Config.tmux_close_arg)
  end)

  it("rejects unknown structural fields with their paths without changing current options", function()
    assert.is_true(Config.setup({ backend = { default = "tmux" } }))
    local borrowed, snapshot = Config(), vim.deepcopy(Config())
    local notes = Helpers.notifications(function()
      for _, spec in ipairs({
        { opts = { backned = false }, field = "backned" },
        { opts = { backend = { tmxu = {} } }, field = "backend.tmxu" },
        { opts = { backend = { tmux = { socket = "aviary-pigeon" } } }, field = "backend.tmux.socket" },
        { opts = { backend = { tmux = { widht = 42 } } }, field = "backend.tmux.widht" },
        { opts = { backend = { tmux = { [1] = false } } }, field = "backend.tmux.1" },
        { opts = { tools = { codex = { commnad = { "other" } } } }, field = "tools.codex.commnad" },
        {
          opts = { tools = { custom = { command = { "custom" }, foramt = false } } },
          field = "tools.custom.foramt",
        },
      }) do
        local ok, reason = Config.setup(spec.opts)
        assert.is_false(ok)
        assert.are.equal("pigeon: unknown option " .. spec.field, reason)
        assert.is_true(rawequal(borrowed, Config()))
        assert.are.same(snapshot, Config())
      end
    end)
    assert.are.same({}, notes)
  end)

  it("accepts native percentage and cell strings without resolving geometry during setup", function()
    for _, value in ipairs({ "1%", "33%", "90%", "100%", "1", "80", "101%" }) do
      assert.is_true(Config.setup({ backend = { tmux = { width = value, height = value } } }))
      assert.are.equal(value, Config().backend.tmux.width)
      assert.are.equal(value, Config().backend.tmux.height)
    end
    assert.is_nil(package.loaded["aviary.pigeon.backends.tmux"])
  end)

  it("rejects malformed options quietly without changing live or borrowed options", function()
    Config.setup({ backend = { default = "tmux" } })
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
        { backend = false },
        { backend = { default = "zellij" } },
        { backend = { tmux = false } },
        { backend = { tmux = { width = 0.9 } } },
        { backend = { tmux = { width = "bad" } } },
        { backend = { tmux = { width = "0%" } } },
        { backend = { tmux = { height = 0 } } },
        { backend = { tmux = { width = -0.5 } } },
        { backend = { tmux = { width = math.huge } } },
        { backend = { tmux = { height = -math.huge } } },
        { backend = { tmux = { height = 0 / 0 } } },
        { backend = { tmux = { height = false } } },
        { backend = { tmux = { width = {} } } },
        { backend = { tmux = { close = "" } } },
      }) do
        local ok, reason = Config.setup(opts)
        assert.is_false(ok)
        assert.is_truthy(reason:find("pigeon:", 1, true))
        assert.are.same(before, Config())
        assert.are.same(before, borrowed)
      end
    end)
    assert.are.same({}, notes)
  end)

  it("does not acquire resources or check executables during setup", function()
    assert.is_true(Config.setup({
      tools = {
        missing = {
          command = { "/no-such-program" },
          format = function(path)
            return path
          end,
        },
      },
      backend = { default = "tmux", tmux = { close = "invalid-until-used" } },
    }))
    assert.is_nil(package.loaded["aviary.pigeon.backends.tmux"])
  end)

  it("accepts tools without a format and keeps the default selectable at send time", function()
    local format = function(path)
      return "!" .. path
    end
    assert.is_true(Config.setup({
      format = format,
      tools = { custom = { command = { "my-cli" } } },
    }))
    assert.are.equal(format, Config().format)
    assert.is_nil(Config().tools.custom.format)
    assert.is_nil(Config().tools.codex.format)
    assert.are.equal("function", type(Config().tools.claude.format))
    Config.setup()
    assert.are.equal("a :L2-3", Config().format("a", 2, 3))
  end)
end)
