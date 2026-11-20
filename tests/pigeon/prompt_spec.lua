---@module 'luassert'
---@diagnostic disable: duplicate-set-field
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")

describe("aviary.pigeon prompt action", function()
  local Config, agent, reference, delivered, notes, items, options, choose
  local saved_select, saved_notify

  local function fake_agent()
    return {
      eval = function(_, ref)
        local text = ref.path
        if ref.start_row then
          text = text .. ":" .. ref.start_row
          if ref.end_row and ref.end_row ~= ref.start_row then
            text = text .. "-" .. ref.end_row
          end
        end
        return "<" .. text .. ">"
      end,
      send = function(_, text)
        delivered[#delivered + 1] = text
      end,
    }
  end

  local function run()
    Config().actions.prompt(agent, reference)
  end

  before_each(function()
    Helpers.reload_pigeon()
    Config = require("aviary.pigeon.config")
    Config.setup()
    delivered, notes = {}, {}
    reference = { path = "/tmp/proj/a.lua", start_row = 2, end_row = 3 }
    agent = fake_agent()
    saved_select, saved_notify = vim.ui.select, vim.notify
    vim.ui.select = function(list, opts, done)
      items, options, choose = list, opts, done
    end
    vim.notify = function(text)
      notes[#notes + 1] = text
    end
  end)

  after_each(function()
    vim.ui.select, vim.notify = saved_select, saved_notify
    Helpers.reload_pigeon()
  end)

  it("renders built-in file and line templates with the agent formatter", function()
    run()
    assert.are.same({ "{file}", "{line}" }, items)
    assert.are.equal("Prompt: ", options.prompt)
    choose("{line}")
    assert.are.same({ "</tmp/proj/a.lua:2-3> " }, delivered)
  end)

  it("renders a whole-file reference and a single captured row", function()
    reference = { path = "/tmp/proj/a.lua" }
    run()
    choose("{file}")
    assert.are.same({ "</tmp/proj/a.lua> " }, delivered)

    delivered = {}
    reference = { path = "/tmp/proj/a.lua", start_row = 5 }
    run()
    choose("{line}")
    assert.are.same({ "</tmp/proj/a.lua:5> " }, delivered)
  end)

  it("expands custom resolvers with the terminal and reference and keeps unknown tokens literal", function()
    local calls = {}
    Config.setup({
      prompts = { custom = "100% {z} {line} {nope} {custom} {custom}\n" },
      resolvers = {
        custom = function(term, ref)
          calls[#calls + 1] = { term, ref }
          return "X"
        end,
      },
    })
    run()
    choose("custom")
    assert.are.equal(2, #calls)
    assert.are.equal(agent, calls[1][1])
    assert.are.equal(reference, calls[1][2])
    assert.are.same({ "100% {z} </tmp/proj/a.lua:2-3> {nope} X X\n" }, delivered)
  end)

  it("captures templates before opening the selector", function()
    Config.setup({ prompts = { review = "{file}" } })
    run()
    Config.setup({ prompts = { review = "changed {file}" } })
    choose("review")
    assert.are.same({ "</tmp/proj/a.lua>" }, delivered)
  end)

  it("sends nothing on cancellation", function()
    run()
    choose(nil)
    assert.are.same({}, delivered)
    assert.are.same({}, notes)
  end)

  it("reports resolver failures once without sending", function()
    Config.setup({
      prompts = { bad = "{boom}" },
      resolvers = {
        boom = function()
          error("boom", 0)
        end,
      },
    })
    run()
    choose("bad")
    assert.are.same({}, delivered)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("boom", 1, true))
  end)
end)
