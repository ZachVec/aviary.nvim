---@module 'luassert'

local Review = require("aviary.hawk.review")

describe("aviary.hawk", function()
  local hawk, create, select_ui, calls
  before_each(function()
    hawk = require("aviary").hawk
    create, select_ui = Review.create, vim.ui.select
    calls = {}
    Review.create = function(...)
      assert.are.equal(1, select("#", ...))
      local instance = {
        focused = 0,
        focus = function(self)
          self.focused = self.focused + 1
        end,
      }
      calls[#calls + 1] = { close = ..., instance = instance }
      return instance
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function()
      error("opening Review must not select a feature")
    end
  end)
  after_each(function()
    if #calls > 0 then
      calls[#calls].close()
    end
    Review.create, vim.ui.select = create, select_ui
  end)

  it("exposes setup and show without installing a command", function()
    assert.is_function(hawk.setup)
    assert.is_function(hawk.show)
    assert.are.equal(0, vim.fn.exists(":Hawk"))
  end)

  it("opens Review directly and reuses it until closure", function()
    assert.are.equal(0, select("#", hawk.show()))
    hawk.show()
    assert.are.equal(1, #calls)
    assert.are.equal(2, calls[1].instance.focused)
    calls[1].close()
    hawk.show()
    assert.are.equal(2, #calls)
    assert.are.equal(1, calls[2].instance.focused)
  end)

  it("propagates creation errors and allows retrying", function()
    local construct = Review.create
    Review.create = function()
      error("creation failed", 0)
    end
    assert.has_error(hawk.show, "creation failed")
    assert.are.same({}, calls)
    Review.create = construct
    hawk.show()
    assert.are.equal(1, #calls)
  end)

  it("propagates focus errors without replacing the live Review", function()
    hawk.show()
    local instance = calls[1].instance
    local focus = instance.focus
    instance.focus = function()
      error("focus failed", 0)
    end
    assert.has_error(hawk.show, "focus failed")
    instance.focus = focus
    hawk.show()
    assert.are.equal(1, #calls)
    assert.are.equal(2, instance.focused)
  end)
end)
