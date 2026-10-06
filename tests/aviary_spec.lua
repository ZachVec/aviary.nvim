---@module 'luassert'

describe("aviary", function()
  it("loads, exposes setup, and holds a config table", function()
    local aviary = require("aviary")
    assert.are.equal("table", type(aviary))
    assert.are.equal("function", type(aviary.setup))
    assert.are.equal("table", type(aviary.config))
  end)

  it("merges each subsystem's slice and never loads it", function()
    local aviary = require("aviary")
    aviary.setup({
      hawk = { position = "left" },
      pigeon = {
        picker = "snacks",
        format = function(file)
          return file
        end,
      },
    })
    assert.are.equal("left", aviary.config.hawk.position)
    assert.are.equal("snacks", aviary.config.pigeon.picker)
    assert.are.equal("function", type(aviary.config.pigeon.format))
    assert.is_nil(package.loaded["aviary.hawk"])
    assert.is_nil(package.loaded["aviary.pigeon"])
  end)

  it("merges a later setup over an earlier one", function()
    local aviary = require("aviary")
    aviary.setup({ hawk = { position = "left" } })
    aviary.setup({ hawk = { size = "40%" } })
    assert.are.equal("left", aviary.config.hawk.position)
    assert.are.equal("40%", aviary.config.hawk.size)
  end)

  it("returns itself from setup", function()
    local aviary = require("aviary")
    assert.are.equal(aviary, aviary.setup({}))
  end)

  it("lazily loads a subsystem when it is named", function()
    package.preload["aviary.fake"] = function()
      return { loaded = true }
    end
    local aviary = require("aviary")
    assert.is_true(aviary.fake.loaded)
    assert.is_true(package.loaded["aviary.fake"].loaded)
    package.preload["aviary.fake"] = nil
    package.loaded["aviary.fake"] = nil
  end)

  it("sets no global", function()
    require("aviary")
    assert.is_nil(rawget(_G, "Aviary"))
  end)
end)
