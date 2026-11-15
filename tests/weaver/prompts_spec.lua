---@module 'luassert'

local Helpers = require("weaver.helpers")
local Message = require("aviary.shared.message")
local format = Helpers.format

describe("aviary.weaver prompts", function()
  local Config, Weaver
  local original_select
  local submitted
  local restore_delivery
  local bufs = {}

  --- A named scratch buffer, wiped after the test.
  ---@param path string
  ---@return integer
  local function named(path)
    local buf = Helpers.buffer({ "a", "b", "c" }, path)
    bufs[#bufs + 1] = buf
    return buf
  end

  --- Choose a configured template through the flow and capture its Message.
  ---@param template string
  ---@param buf integer
  ---@param row integer
  ---@return aviary.shared.Message
  local function choose(template, buf, row)
    Config.setup({ prompts = { test = template } })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    submitted = nil
    Weaver.prompt()
    return assert(submitted)
  end

  --- A target with only a working directory.
  ---@param cwd string?
  ---@return aviary.shared.message.RenderCtx
  local function target(cwd)
    return { cwd = cwd, format = format }
  end

  setup(function()
    Helpers.reload_weaver()
    Config = require("aviary.weaver.config")
    original_select = vim.ui.select
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(_, _, on_choice)
      on_choice("test")
    end
    Weaver = require("aviary").weaver
  end)

  before_each(function()
    restore_delivery = Helpers.delivery(function(message)
      submitted = message
    end)
    Config.setup()
  end)

  teardown(function()
    vim.ui.select = original_select
    Helpers.reload_weaver()
  end)

  after_each(function()
    restore_delivery()
    for _, buf in ipairs(bufs) do
      Helpers.wipe(buf)
    end
    bufs = {}
  end)

  it("spells {file} and {line} relative to the target's cwd without notifying", function()
    local buf = named("/tmp/proj/src/a.lua")
    local notes = Helpers.notifications(function()
      assert.are.equal("src/a.lua", (choose("{file}", buf, 1):eval(target("/tmp/proj"))))
      assert.are.equal("src/a.lua[3]", (choose("{line}", buf, 3):eval(target("/tmp/proj"))))
    end)
    assert.are.same({}, notes)
  end)

  it("renders per target: absolute with no cwd, absolute outside it", function()
    local buf = named("/tmp/proj/src/a.lua")
    local message = choose("{file}", buf, 1)
    assert.are.equal("src/a.lua", (message:eval(target("/tmp/proj"))))
    assert.are.equal("/tmp/proj/src/a.lua", (message:eval(target(nil))))
    assert.are.equal("/tmp/proj/src/a.lua", (message:eval(target("/elsewhere"))))
  end)

  it("captures reversed Visual lines for {line} before choosing a template", function()
    local buf = named("/tmp/proj/a.lua")
    Config.setup({ prompts = { test = "{line} {file}" } })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 1, 0, {})
    vim.cmd.normal({ args = { "3Gvk" }, bang = true })
    Weaver.prompt()
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    assert.are.equal("a.lua[2,3] a.lua", (submitted:eval(target("/tmp/proj"))))
  end)

  it("keeps a multi-line template's shape", function()
    local buf = named("/tmp/proj/a.lua")
    local message = choose("look at {file}\nand {line}", buf, 2)
    assert.are.equal("look at a.lua\nand a.lua[2]", (message:eval(target("/tmp/proj"))))
  end)

  it("fails the whole message when a placeholder has no reference", function()
    local buf = Helpers.buffer({ "a" }) -- unnamed: {file} has nothing to spell
    bufs[#bufs + 1] = buf
    local rendered, why = choose("{file} and {line}", buf, 1):eval(target("/tmp"))
    assert.is_nil(rendered)
    assert.is_truthy(assert(why):find("reference", 1, true))
  end)

  it("sends an unknown token verbatim without notifying", function()
    local buf = named("/tmp/proj/a.lua")
    local notes = Helpers.notifications(function()
      assert.are.equal("x{nope}y", (choose("x{nope}y", buf, 1):eval(target("/tmp/proj"))))
    end)
    assert.are.same({}, notes)
  end)

  it("preserves adjacent placeholders, punctuation, percent signs and trailing newlines", function()
    local buf = named("/tmp/proj/a.lua")
    Helpers.notifications(function()
      local message = choose("100% ({file}){nope}{line}\n\n", buf, 2)
      assert.are.equal("100% (a.lua){nope}a.lua[2]\n\n", (message:eval(target("/tmp/proj"))))
    end)
    assert.are.equal("", (choose("", buf, 2):eval({ format = format })))
  end)

  it("preserves repeated unknown tokens and their order without notifying", function()
    local buf = named("/tmp/proj/a.lua")
    local notes = Helpers.notifications(function()
      assert.are.equal("{z} {nope} {z}", (choose("{z} {nope} {z}", buf, 1):eval(target("/tmp/proj"))))
    end)
    assert.are.same({}, notes)
  end)

  it("expands only the selected template", function()
    local buf = named("/tmp/proj/a.lua")
    vim.api.nvim_set_current_buf(buf)
    Config.setup({
      prompts = { test = "{file}", unused = "{broken}" },
      resolvers = {
        broken = function()
          error("unselected resolver ran")
        end,
      },
    })
    local notes = Helpers.notifications(function()
      Weaver.prompt()
    end)
    assert.are.same({}, notes)
    assert.are.equal("a.lua", (submitted:eval(target("/tmp/proj"))))
  end)

  it("adds resolvers and overrides built-ins in token order, once per occurrence", function()
    local buf = named("/tmp/proj/a.lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local calls = {}
    assert.is_true(Weaver.setup({
      prompts = { test = "{file}{custom_2}{nope}{line}{custom_2}" },
      resolvers = {
        file = function(selection)
          calls[#calls + 1] = "file"
          assert.are.same({ path = "/tmp/proj/a.lua", start_row = 2 }, selection)
          return Message.text("overridden")
        end,
        custom_2 = function()
          calls[#calls + 1] = "custom"
          return Message.text("<" .. #calls .. ">")
        end,
      },
    }))
    Weaver.prompt()
    assert.are.same({ "file", "custom", "custom" }, calls)
    assert.are.equal("overridden<2>{nope}a.lua[2]<3>", (submitted:eval(target("/tmp/proj"))))
  end)
end)
