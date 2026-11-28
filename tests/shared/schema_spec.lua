---@module 'luassert'

local Schema = require("aviary.shared.schema")

describe("aviary.shared.schema", function()
  it("merges nested defaults in order and returns independent tables", function()
    local keys = { close = { "q", "x" } }
    local schema = Schema.object({
      panel = Schema.object({
        view = Schema.object({
          width = Schema.number(),
          height = Schema.number(),
          border = Schema.string({ default = "rounded" }),
        }, { default = { width = 40, height = 24 } }),
        keys = Schema.object({ [Schema.string()] = Schema.array("string") }, { default = { open = { "o" } } }),
      }, { default = { view = { height = 20 } } }),
    }, { default = { panel = { view = { width = 80 }, keys = keys } } })
    local overrides = { panel = { view = { border = "single" }, keys = { close = {} } } }

    local result = assert(Schema.resolve(schema, overrides, "example"))
    assert.are.same({ width = 80, height = 20, border = "single" }, result.panel.view)
    assert.are.same({ close = {}, open = { "o" } }, result.panel.keys)
    result.panel.keys.open[1] = "new"
    result.panel.keys.close[1] = "new"
    assert.are.same({}, overrides.panel.keys.close)
    assert.are.same({ close = { "q", "x" }, open = { "o" } }, assert(Schema.resolve(schema, {}, "example")).panel.keys)
  end)

  it("identifies fields and array indexes in validation errors", function()
    local schema = Schema.object({
      tools = Schema.object({
        [Schema.string()] = Schema.object({ command = Schema.array("string", { min = 1 }) }),
      }),
    })
    local value, reason =
      Schema.resolve(schema, { tools = { ["my.tool"] = { command = { "tool", false } } } }, "example")
    assert.is_nil(value)
    assert.are.equal('example: tools["my.tool"].command[2] must be a string', reason)
  end)
end)
