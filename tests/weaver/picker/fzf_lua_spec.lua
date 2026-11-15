---@module 'luassert'

local Helpers = require("weaver.picker.helpers")

describe("aviary.weaver.picker.fzf_lua", function()
  local Picker, source, opts, parsed

  before_each(function()
    Helpers.reload_picker()
    parsed = {}
    local function capture(name)
      return function(options)
        source, opts = name, options
      end
    end
    package.loaded["fzf-lua"] = { files = capture("files"), buffers = capture("buffers") }
    package.loaded["fzf-lua.path"] = {
      entry_to_file = function(line, options)
        assert.is_true(rawequal(opts, options))
        parsed[#parsed + 1] = line
        return { path = #parsed == 1 and "/tmp/a.lua" or "/tmp/b.lua" }
      end,
    }
    Picker = require("aviary.weaver.picker")
    require("aviary.weaver.config").setup({ picker = "fzf-lua" })
  end)

  after_each(function()
    package.loaded["fzf-lua"] = nil
    package.loaded["fzf-lua.path"] = nil
    Helpers.reload_picker()
  end)

  it("uses built-in files with the captured cwd and follows symlinks", function()
    Picker.pick("files", function() end)
    assert.are.equal("files", source)
    assert.are.equal(vim.fs.normalize(vim.fn.getcwd(-1, -1)), opts.cwd)
    assert.is_true(opts.follow)
  end)

  it("parses and defers each confirmation, including resumed selections", function()
    local chosen
    Picker.pick("files", function(paths)
      chosen = paths
    end)
    local lines = { "icon a.lua", "[42] + b.lua:10" }
    opts.actions.default(lines, opts)
    assert.is_nil(chosen)
    vim.wait(500, function()
      return chosen ~= nil
    end)
    assert.are.same(lines, parsed)
    assert.are.same({ "/tmp/a.lua", "/tmp/b.lua" }, chosen)

    chosen = nil
    opts.actions.default({ lines[2] }, opts)
    assert.is_nil(chosen)
    vim.wait(500, function()
      return chosen ~= nil
    end)
    assert.are.same({ "/tmp/b.lua" }, chosen)
  end)

  it("does not confirm empty selections", function()
    local confirmed = false
    Picker.pick("files", function()
      confirmed = true
    end)
    opts.actions.default({}, opts)
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    vim.wait(500, function()
      return drained
    end)
    assert.is_false(confirmed)
  end)

  it("keeps buffers outside cwd eligible and filters non-file buffers", function()
    Picker.pick("buffers", function() end)
    assert.are.equal("buffers", source)
    assert.is_nil(opts.cwd)
    Helpers.check_buffer_filter(opts.filter)
  end)
end)
