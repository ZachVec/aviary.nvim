---@module 'luassert'

local Snapshot = require("aviary.hawk.snapshot")
local h = require("hawk.helpers")

describe("aviary.hawk", function()
  local hawk, new, cwd, dir, source
  before_each(function()
    hawk, new = require("aviary").hawk, Snapshot.new
    cwd, dir, source = vim.fn.getcwd(-1, -1), h.repo(), vim.api.nvim_get_current_win()
    vim.cmd.cd(dir)
  end)

  after_each(function()
    Snapshot.new = new
    vim.cmd.cd(cwd)
    h.cleanup(source, dir)
    h.flush()
  end)

  it("opens and focuses a fresh tab on every call without installing a command", function()
    assert.is_function(hawk.setup)
    assert.are.equal(0, vim.fn.exists(":Hawk"))
    assert.are.equal(0, select("#", hawk.show()))
    local first = vim.api.nvim_get_current_tabpage()
    assert.are.equal("aviary_hawk", vim.bo.filetype)
    hawk.show()
    assert.are_not.equal(first, vim.api.nvim_get_current_tabpage())
    assert.is_true(vim.api.nvim_tabpage_is_valid(first))
    assert.are.equal("aviary_hawk", vim.bo.filetype)
    assert.are.same({ "direct", " ", " " }, h.lines(vim.api.nvim_get_current_buf()))
  end)

  it("propagates creation failures and permits another call", function()
    local tabs = vim.api.nvim_list_tabpages()
    local buffers = vim.api.nvim_list_bufs()
    Snapshot.new = function()
      error("creation failed", 0)
    end
    assert.has_error(hawk.show, "creation failed")
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    Snapshot.new = new
    hawk.show()
    assert.are.equal("aviary_hawk", vim.bo.filetype)
  end)
end)
