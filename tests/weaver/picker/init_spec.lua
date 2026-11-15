---@module 'luassert'

local Helpers = require("weaver.picker.helpers")

describe("aviary.weaver.picker", function()
  local Picker

  before_each(function()
    Helpers.reload_picker()
    Picker = require("aviary.weaver.picker")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
    package.loaded["fzf-lua"] = nil
    package.preload["fzf-lua"] = nil
    Helpers.reload_picker()
  end)

  it("defaults to Snacks and resolves the current backend at each use", function()
    local sources = {}
    package.loaded["snacks"] = {
      picker = {
        pick = function(source)
          sources[#sources + 1] = "snacks:" .. source
        end,
      },
    }
    package.loaded["fzf-lua"] = {
      buffers = function()
        sources[#sources + 1] = "fzf-lua:buffers"
      end,
    }
    Picker.pick("files", function() end)
    require("aviary.weaver.config").setup({ picker = "fzf-lua" })
    Picker.pick("buffers", function() end)
    assert.are.same({ "snacks:files", "fzf-lua:buffers" }, sources)
  end)

  it("checks backend availability at use, not setup", function()
    package.preload["fzf-lua"] = function()
      error("not installed")
    end
    assert.is_true(require("aviary.weaver.config").setup({ picker = "fzf-lua" }))
    local ok, err = pcall(Picker.pick, "buffers", function() end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("picker 'fzf-lua' requires 'fzf-lua'", 1, true))
  end)
end)
