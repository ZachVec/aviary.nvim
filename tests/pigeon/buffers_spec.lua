---@module 'luassert'
---@diagnostic disable: duplicate-set-field
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")

describe("aviary.pigeon buffers action", function()
  local Config, agent, delivered, notes, items, options, choose
  local saved_select, saved_notify, saved_listed, owned

  local function named(listed)
    local buffer = vim.api.nvim_create_buf(listed ~= false, false)
    local name = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(buffer, name)
    owned[#owned + 1] = buffer
    return name
  end

  local function run()
    Config().actions.buffers(function()
      return agent
    end, { path = "" })
  end

  before_each(function()
    Helpers.reload_pigeon()
    Config = require("aviary.pigeon.config")
    Config.setup()
    delivered, notes, items, options, choose = {}, {}, nil, nil, nil
    agent = {
      eval = function(_, reference)
        return "<" .. reference.path .. ">"
      end,
      send = function(_, text)
        delivered[#delivered + 1] = text
      end,
    }
    saved_select, saved_notify = vim.ui.select, vim.notify
    vim.ui.select = function(list, opts, done)
      items, options, choose = list, opts, done
    end
    vim.notify = function(text)
      notes[#notes + 1] = text
    end
    saved_listed, owned = {}, {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buffer].buflisted then
        saved_listed[buffer] = true
        vim.bo[buffer].buflisted = false
      end
    end
  end)

  after_each(function()
    for buffer in pairs(saved_listed) do
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.bo[buffer].buflisted = true
      end
    end
    for _, buffer in ipairs(owned) do
      if vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    vim.cmd("stopinsert")
    vim.ui.select, vim.notify = saved_select, saved_notify
    Helpers.reload_pigeon()
  end)

  it("lists named file-backed listed buffers and sends the selected path", function()
    local first = named()
    local second = named()
    named(false)
    local scratch = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(scratch, vim.fn.tempname() .. ".lua")
    owned[#owned + 1] = scratch
    local unnamed = vim.api.nvim_create_buf(true, false)
    owned[#owned + 1] = unnamed

    run()
    local choices, expected = vim.deepcopy(items), { first, second }
    table.sort(choices)
    table.sort(expected)
    assert.are.same(expected, choices)
    assert.are.equal("Buffer: ", options.prompt)
    assert.are.equal(vim.fn.fnamemodify(first, ":~:."), options.format_item(first))

    choose(first)
    assert.are.same({ "<" .. first .. ">" }, delivered)
    assert.are.same({}, notes)
  end)

  it("resolves the current Agent once before opening the selector", function()
    named()
    local calls = 0
    Config().actions.buffers(function()
      calls = calls + 1
      return agent
    end, { path = "" })
    assert.are.equal(1, calls)
    assert.are.equal(1, #items)
  end)

  it("sends nothing on cancellation", function()
    named()
    run()
    choose(nil)
    assert.are.same({}, delivered)
    assert.are.same({}, notes)
  end)

  it("warns once when no file buffers are available", function()
    local calls = 0
    Config().actions.buffers(function()
      calls = calls + 1
      return agent
    end, { path = "" })
    assert.are.equal(0, calls)
    assert.is_nil(items)
    assert.are.same({ "pigeon: no file buffers" }, notes)
  end)

  it("reports an Agent resolution failure once without opening the selector", function()
    named()
    Config().actions.buffers(function()
      error("current failed", 0)
    end, { path = "" })
    assert.is_nil(items)
    assert.are.same({}, delivered)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("current failed", 1, true))
  end)

  it("reports rendering failures once without sending", function()
    local name = named()
    agent.eval = function()
      error("eval failed", 0)
    end
    run()
    choose(name)
    assert.are.same({}, delivered)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("eval failed", 1, true))
  end)
end)
