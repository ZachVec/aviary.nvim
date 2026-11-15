---@module 'luassert'
---@type aviary.pigeon.ConfigModule
local Config = require("aviary.pigeon.config")

describe("pigeon tool formats", function()
  before_each(function()
    Config.setup()
  end)

  it("spells Codex paths and raw inclusive ranges", function()
    local format = Config().format
    assert.is_nil(Config().tools.codex.format)
    assert.are.equal("a.lua", format("a.lua"))
    assert.are.equal("a.lua :L7", format("a.lua", 7))
    assert.are.equal("a.lua :L7", format("a.lua", 7, 7))
    assert.are.equal("a.lua :L7-9", format("a.lua", 7, 9))
  end)
  it("spells Claude mentions, quoting unusual paths", function()
    local format = assert(Config().tools.claude.format)
    assert.are.equal("@a/b.lua", format("a/b.lua"))
    assert.are.equal("@a/b.lua#L7", format("a/b.lua", 7, 7))
    assert.are.equal('@"a b.lua"#L7-9', format("a b.lua", 7, 9))
  end)
end)
