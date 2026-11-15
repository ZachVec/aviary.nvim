---@module 'luassert'

local Helpers = require("weaver.helpers")

describe("aviary.weaver.config", function()
  local Config

  before_each(function()
    Helpers.reload_weaver()
    Config = require("aviary.weaver.config")
  end)

  teardown(function()
    Helpers.reload_weaver()
  end)

  it("reads the defaults by calling the module", function()
    assert.are.equal("{file} ", Config().prompts["{file}"])
    assert.are.equal("{line} ", Config().prompts["{line}"])
    assert.are.equal("\n", Config().references.join)
  end)

  it("merges opts over the defaults without dropping their siblings", function()
    Config.setup({ prompts = { review = "Review {file}" } })
    assert.are.equal("Review {file}", Config().prompts.review)
    assert.are.equal("{line} ", Config().prompts["{line}"])
  end)

  it("rebuilds from the defaults on every setup", function()
    local file = Config().resolvers.file
    Config.setup({
      prompts = { review = "Review {file}" },
      references = { join = " " },
      resolvers = { file = function() end, custom = function() end },
    })
    Config.setup()
    assert.is_nil(Config().prompts.review)
    assert.is_nil(Config().resolvers.custom)
    assert.are.equal(file, Config().resolvers.file)
    assert.are.equal("\n", Config().references.join)
  end)

  it("rejects unknown structural fields with their paths without changing current options", function()
    assert.is_true(Config.setup({ prompts = { custom = "Review {file}" }, references = { join = " " } }))
    local borrowed, snapshot = Config(), vim.deepcopy(Config())
    local notes = Helpers.notifications(function()
      for _, spec in ipairs({
        { opts = { piker = "fzf-lua" }, field = "piker" },
        { opts = { references = { jon = " " } }, field = "references.jon" },
        { opts = { references = { [1] = false } }, field = "references.1" },
      }) do
        local ok, message = Config.setup(spec.opts)
        assert.is_false(ok)
        assert.are.equal("weaver: unknown option " .. spec.field, message)
        assert.is_true(rawequal(borrowed, Config()))
        assert.are.same(snapshot, Config())
      end
    end)
    assert.are.same({}, notes)
  end)

  it("rejects invalid options quietly and retains the previous configuration", function()
    assert.is_true(Config.setup({ prompts = { custom = "Review {file}" }, references = { join = " " } }))
    local before = Config()
    local snapshot = vim.deepcopy(before)
    local notes = Helpers.notifications(function()
      for _, spec in ipairs({
        { opts = { prompts = { bad = 42 } }, field = "prompts" },
        { opts = { prompts = false }, field = "prompts" },
        { opts = { resolvers = false }, field = "resolvers" },
        { opts = { resolvers = { custom = "text" } }, field = "resolvers" },
        { opts = { resolvers = { [1] = function() end } }, field = "resolvers" },
        { opts = { references = { join = 42 } }, field = "references.join" },
        { opts = { references = false }, field = "references" },
        { opts = false, field = "options" },
        { opts = 42, field = "options" },
      }) do
        local ok, message = Config.setup(spec.opts)
        assert.is_false(ok)
        assert.are.equal("string", type(message))
        assert.is_truthy(message:find("weaver:", 1, true))
        assert.is_truthy(message:find(spec.field, 1, true))
        assert.is_truthy(message:find("must", 1, true))
        assert.are.same(snapshot, Config())
        assert.are.same(snapshot, before)
      end
    end)
    assert.are.same({}, notes)
  end)
end)
