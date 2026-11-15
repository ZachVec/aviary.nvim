---@module 'luassert'

local Helpers = require("weaver.helpers")
local Message = require("aviary.shared.message")
local format = Helpers.format

describe("aviary.weaver flows", function()
  local Config
  local Weaver
  local pick_source
  local select_items, select_choice, original_select
  local pick_confirm
  local delivered_message
  local restore_delivery
  local bufs = {}
  local function receive(message)
    delivered_message = message
  end

  --- A named scratch buffer, wiped after the test.
  ---@param path string
  ---@param lines? string[]
  ---@return integer
  local function named(path, lines)
    local buf = Helpers.buffer(lines or { "a", "b", "c" }, path)
    bufs[#bufs + 1] = buf
    return buf
  end

  local function change_focus()
    local floating = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = floating
    vim.api.nvim_set_current_buf(floating)
  end

  setup(function()
    Helpers.reload_weaver()
    Config = require("aviary.weaver.config")

    original_select = vim.ui.select
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, on_choice)
      select_items, select_choice = items, on_choice
      change_focus()
    end
    local picker = {}
    function picker.pick(source, on_confirm)
      pick_source, pick_confirm = source, on_confirm
      change_focus()
    end
    package.loaded["aviary.weaver.picker"] = picker

    Weaver = require("aviary").weaver
  end)

  teardown(function()
    vim.ui.select = original_select
    Helpers.clear_picker_mock()
    Helpers.reload_weaver()
  end)

  before_each(function()
    restore_delivery = Helpers.delivery(receive)
    Config.setup()
    pick_source, pick_confirm, select_items, select_choice = nil, nil, nil, nil
    delivered_message = nil
  end)

  after_each(function()
    restore_delivery()
    for _, buf in ipairs(bufs) do
      Helpers.wipe(buf)
    end
    bufs = {}
  end)

  it("offers the prompt names and renders from the invoking buffer, not the pick", function()
    local buf = named("/tmp/proj/src/a.lua")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    Weaver.prompt()
    vim.api.nvim_buf_set_name(buf, "/tmp/proj/later.lua")
    assert.are.same({ "{file}", "{line}" }, select_items)

    select_choice("{line}")
    Helpers.wipe(buf)
    assert.are.equal("src/a.lua[2] ", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
    assert.are.equal("/tmp/proj/src/a.lua[2] ", (delivered_message:eval({ format = format })))
  end)

  it("offers every configured prompt, user entries included, in a stable order", function()
    Config.setup({ prompts = { review = "Review {file}" } })

    Weaver.prompt()

    assert.are.same({ "review", "{file}", "{line}" }, select_items)
  end)

  it("freezes the Visual range before the prompt picker changes focus", function()
    local buf = named("/tmp/proj/a.lua")
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("normal! 3GVk")
    Weaver.prompt()
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    assert.are_not.equal(buf, vim.api.nvim_get_current_buf())
    assert.is_nil(delivered_message)
    vim.api.nvim_buf_set_name(buf, "/tmp/proj/renamed.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
    Helpers.wipe(buf)
    select_choice("{line}")
    assert.are.equal("a.lua[2,3] ", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("keeps a trailing space in the built-in template and preserves override spacing", function()
    local buf = named("/tmp/proj/a.lua")
    vim.api.nvim_set_current_buf(buf)
    Weaver.prompt()
    select_choice("{file}")
    assert.are.equal("a.lua ", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))

    Config.setup({ prompts = { ["{file}"] = " ({file}) " } })
    vim.api.nvim_set_current_buf(buf)
    Weaver.prompt()
    select_choice("{file}")
    assert.are.equal(" (a.lua) ", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("delivers the references chosen from a source", function()
    Weaver.files()
    assert.are.equal("files", pick_source)

    pick_confirm({ "/tmp/proj/a.lua", "/tmp/proj/b.lua" })
    assert.are.equal("a.lua\nb.lua", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("does not export while file selection is pending", function()
    Weaver.files()
    assert.is_nil(delivered_message)
  end)

  it("cancels prompt selection without exporting", function()
    Weaver.prompt()
    select_choice(nil)
    assert.is_nil(delivered_message)
  end)

  it("delivers references from the buffers source", function()
    Config.setup({ references = { join = " " } })
    Weaver.buffers()
    assert.are.equal("buffers", pick_source)
    pick_confirm({ "/tmp/proj/a.lua", "/tmp/proj/b.lua" })
    assert.are.equal("a.lua b.lua", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("sends the line under the cursor verbatim", function()
    local buf = named("/tmp/proj/a.lua", { "one", "two", "three" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    Weaver.text()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "later" })
    assert.are.equal("two", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("sends the active Visual range rather than stale selection marks", function()
    local buf = named("/tmp/proj/a.lua", { "one", "two", "three" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 1, 0, {})
    vim.cmd("normal! 2GVj")
    assert.are.equal("V", vim.api.nvim_get_mode().mode)
    assert.are.same({ 1, 1 }, { vim.fn.line("'<"), vim.fn.line("'>") })

    Weaver.text()
    vim.cmd("normal! \27")
    assert.are.equal("two\nthree", (delivered_message:eval({ format = format })))
  end)

  it("sends an empty line as valid empty text", function()
    local buf = named("/tmp/proj/a.lua", { "" })
    vim.api.nvim_win_set_buf(0, buf)
    Weaver.text()
    assert.are.equal("", (delivered_message:eval({ format = format })))
  end)

  it("freezes templates across setup while prompt selection is pending", function()
    vim.api.nvim_set_current_buf(named("/tmp/proj/a.lua"))
    Config.setup({ prompts = { example = "before {file}" } })
    Weaver.prompt()
    Config.setup({ prompts = { example = "after {line}" } })
    select_choice("example")
    assert.are.equal("before a.lua", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
  end)

  it("passes the captured Selection to the selected resolver after confirmation", function()
    local buf = named("/tmp/proj/a.lua")
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("normal! 3GVk")
    local received
    assert.is_true(Weaver.setup({
      prompts = { example = "before {range}" },
      resolvers = {
        range = function(selection)
          received = selection
          return Message.join(" + ", {
            Message.reference(selection.path, selection.start_row, selection.end_row),
            Message.text("custom"),
          })
        end,
      },
    }))
    Weaver.prompt()
    assert.is_nil(received)
    assert.are_not.equal(buf, vim.api.nvim_get_current_buf())
    assert.is_true(Weaver.setup({
      prompts = { example = "after {range}" },
      resolvers = {
        range = function()
          error("new resolver ran for a pending picker")
        end,
      },
    }))
    vim.api.nvim_buf_set_name(buf, "/tmp/proj/renamed.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
    Helpers.wipe(buf)
    select_choice("example")
    assert.are.same({ path = "/tmp/proj/a.lua", start_row = 2, end_row = 3 }, received)
    assert.are.equal("before a.lua[2,3] + custom", (delivered_message:eval({ cwd = "/tmp/proj", format = format })))
    assert.are.equal("before /tmp/proj/a.lua[2,3] + custom", (delivered_message:eval({ format = format })))
  end)

  it("skips resolvers on cancellation and propagates resolver errors on confirmation", function()
    local calls = 0
    assert.is_true(Weaver.setup({
      prompts = { example = "{broken}" },
      resolvers = {
        broken = function()
          calls = calls + 1
          error("resolver failed", 0)
        end,
      },
    }))
    Weaver.prompt()
    select_choice(nil)
    assert.are.equal(0, calls)
    Weaver.prompt()
    assert.has_error(function()
      select_choice("example")
    end, "resolver failed")
    assert.are.equal(1, calls)
    assert.is_nil(delivered_message)
  end)

  it("propagates delivery callback errors", function()
    require("aviary").pigeon.send = function()
      error("caller failed", 0)
    end
    Weaver.prompt()
    assert.has_error(function()
      select_choice("{file}")
    end, "caller failed")
  end)
end)
