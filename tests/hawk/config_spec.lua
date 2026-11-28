---@module 'luassert'

local config = require("aviary.hawk.config")

describe("Hawk Review options", function()
  after_each(function()
    config.setup()
  end)

  it("replaces key sets including empty sets and preserves other defaults", function()
    assert.is_true(config.setup({ keymaps = { close = {}, hawk = { "o" } } }))
    assert.are.same({}, config().keymaps.close)
    assert.are.same({ "o" }, config().keymaps.hawk)
    assert.are.same({ "r" }, config().keymaps.refresh)
    assert.is_true(config.setup())
    assert.are.same({ "q" }, config().keymaps.close)
    assert.are.same({ "<CR>" }, config().keymaps.hawk)
    assert.are.same({ "X" }, config().keymaps.toggle_all)
  end)

  it("provides handlers for the default keymaps", function()
    for action in pairs(config().keymaps) do
      assert.is_function(config().actions[action])
    end
  end)

  it("accepts custom actions alongside built-ins", function()
    local inspect = function() end
    assert.is_true(config.setup({ keymaps = { inspect = { "i", "I" } }, actions = { inspect = inspect } }))
    assert.are.equal(inspect, config().actions.inspect)
    assert.are.same({ "i", "I" }, config().keymaps.inspect)
    assert.are.same({ "q" }, config().keymaps.close)
  end)

  it("asks a diff row to preview itself in the owning Tab", function()
    local previewed
    local row = {
      kind = "diff",
      jump = function(_, owner)
        previewed = owner
      end,
    }
    ---@type any minimal action receiver
    local tab = {
      current = function()
        return row, 3
      end,
    }
    config().actions.hawk(tab)
    assert.are.equal(tab, previewed)
  end)

  for _, kind in ipairs({ "revision", "choice" }) do
    it("edits the captured " .. kind .. " row and skips cancelled input", function()
      local choices = { "one", "two" }
      local confirm, edited, range
      local row = {
        kind = "meta",
        value = kind == "choice" and "one" or "HEAD",
        input = kind == "choice" and { kind = "choice", choices = choices } or { kind = "revision", root = "/repo" },
        edit = function(_, value)
          edited = value
        end,
      }
      local selected, lnum = row, 2
      ---@type any minimal action receiver
      local tab = {
        current = function()
          return selected, lnum
        end,
        render = function(_, first, last)
          range = { first, last }
        end,
      }
      local input, select_input = vim.ui.input, vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, callback)
        assert.are.equal("revision", kind)
        assert.are.same({ default = "HEAD" }, opts)
        confirm = callback
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(items, opts, callback)
        assert.are.equal("choice", kind)
        assert.are.same(choices, items)
        assert.are.equal("one [current]", opts.format_item("one"))
        assert.are.equal("two", opts.format_item("two"))
        confirm = callback
      end
      local ok, err = pcall(function()
        local hawk = config().actions.hawk
        hawk(tab)
        assert(confirm)(nil)
        assert.is_nil(edited)
        assert.is_nil(range)

        hawk(tab)
        selected, lnum = {}, 1
        assert(confirm)("two")
        assert.are.equal("two", edited)
        assert.are.same({ 1, 2 }, range)
      end)
      vim.ui.input, vim.ui.select = input, select_input
      assert(ok, err)
    end)
  end
end)
