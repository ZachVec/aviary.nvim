---@module 'luassert'

local Helpers = require("weaver.picker.helpers")

describe("aviary.weaver.picker.snacks", function()
  local Picker, source, opts

  before_each(function()
    Helpers.reload_picker()
    package.loaded["snacks"] = {
      picker = {
        pick = function(name, options)
          source, opts = name, options
        end,
        util = {
          path = function(item)
            return item.file
          end,
        },
      },
    }
    Picker = require("aviary.weaver.picker")
  end)

  after_each(function()
    package.loaded["snacks"] = nil
    Helpers.reload_picker()
  end)

  it("uses the built-in files source with the global cwd and symlink following", function()
    local cwd = vim.fn.getcwd(-1, -1)
    local local_dir = vim.fn.tempname()
    vim.fn.mkdir(local_dir, "p")
    vim.cmd.lcd(local_dir)
    local ok, err = pcall(Picker.pick, "files", function() end)
    vim.cmd.lcd(cwd)
    vim.fn.delete(local_dir, "d")
    assert(ok, err)
    assert.are.equal("files", source)
    assert.are.equal(vim.fs.normalize(cwd), opts.cwd)
    assert.is_true(opts.follow)
  end)

  it("maps selections to paths and confirms after cleanup, including resumed selections", function()
    local events, chosen = {}, nil
    local calls = 0
    Picker.pick("files", function(paths)
      calls = calls + 1
      events[#events + 1] = "confirm"
      chosen = paths
    end)
    local items = { { file = "/tmp/a.lua", idx = 1, score = 0 }, { file = "/tmp/b.lua", idx = 2, score = 0 } }
    local surface = {
      selected = function(_, options)
        assert.is_true(options.fallback)
        return vim.deepcopy(items)
      end,
      close = function()
        vim.schedule(function()
          events[#events + 1] = "cleanup"
        end)
      end,
    }
    opts.confirm(surface)
    assert.is_nil(chosen)
    vim.wait(500, function()
      return chosen ~= nil
    end)
    assert.are.same({ "/tmp/a.lua", "/tmp/b.lua" }, chosen)
    assert.are.equal(1, calls)
    assert.are.equal("cleanup", events[1])
    assert.are.equal("confirm", events[2])

    items, chosen = { { file = "/tmp/c.lua" } }, nil
    opts.confirm(surface)
    assert.is_nil(chosen)
    vim.wait(500, function()
      return chosen ~= nil
    end)
    assert.are.same({ "/tmp/c.lua" }, chosen)
    assert.are.equal(2, calls)
    assert.are.equal("cleanup", events[3])
    assert.are.equal("confirm", events[4])
  end)

  it("does not confirm an empty selection", function()
    local confirmed = false
    Picker.pick("files", function()
      confirmed = true
    end)
    opts.confirm({
      selected = function()
        return {}
      end,
      close = function() end,
    })
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    vim.wait(500, function()
      return drained
    end)
    assert.is_false(confirmed)
  end)

  it("uses built-in buffers without restricting cwd and filters non-file buffers", function()
    Picker.pick("buffers", function() end)
    assert.are.equal("buffers", source)
    assert.is_nil(opts.cwd)
    assert.is_false(opts.filter.filter({ file = "/tmp/not-a-buffer.lua" }))
    Helpers.check_buffer_filter(function(buf)
      return opts.filter.filter({ buf = buf })
    end)
  end)
end)
