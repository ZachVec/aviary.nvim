---@module 'luassert'
---@diagnostic disable: duplicate-set-field
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
local Message = require("aviary.shared.message")

describe("aviary.pigeon Terminal routing", function()
  local Pigeon, Backends, choices, choose, options, delivered, notes, fail
  local saved_select, saved_notify
  local first, second
  local function agent(name)
    local self = {
      retargets = {},
      eval = function(_, message)
        return name
          .. ":"
          .. assert(message:eval({
            format = function(path)
              return path
            end,
          }))
      end,
      send = function(_, text)
        delivered[#delivered + 1] = { name, text }
      end,
      attach = function()
        return { "sh", "-c", "sleep 300" }
      end,
    }
    function self:id()
      return name
    end
    function self:resolve()
      return self
    end
    function self:retarget(client)
      if fail == "retarget" and name == "second" then
        error("retarget failed", 0)
      end
      self.retargets[#self.retargets + 1] = client
    end
    return setmetatable(self, {
      __tostring = function()
        return name
      end,
    })
  end
  local function terminal_buffers()
    return vim.tbl_filter(function(buffer)
      return vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "aviary-pigeon"
    end, vim.api.nvim_list_bufs())
  end
  local function terminal_state()
    local buffer = terminal_buffers()[1]
    if not buffer then
      return nil
    end
    local job = vim.b[buffer].terminal_job_id
    return {
      buffer = buffer,
      job = job,
      client = job and vim.api.nvim_get_chan_info(job).pty or nil,
    }
  end
  before_each(function()
    Helpers.reload_pigeon()
    saved_select, saved_notify = vim.ui.select, vim.notify
    delivered, notes, fail, choose, options = {}, {}, nil, nil, nil
    first, second = agent("first"), agent("second")
    choices = { first, second }
    Backends = require("aviary.pigeon.backends")
    Backends.list = function()
      if fail == "list" then
        error("discovery failed", 0)
      end
      return vim.list_slice(choices)
    end
    vim.ui.select = function(items, opts, done)
      choices, options, choose = items, opts, done
    end
    vim.notify = function(text)
      notes[#notes + 1] = text
    end
    Pigeon = require("aviary.pigeon")
  end)
  after_each(function()
    for _, buffer in ipairs(terminal_buffers()) do
      local job = vim.b[buffer].terminal_job_id
      if job and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
    end
    vim.wait(1000, function()
      return #terminal_buffers() == 0
    end)
    vim.ui.select, vim.notify = saved_select, saved_notify
    Helpers.reload_pigeon()
  end)
  local function attach()
    Pigeon.pick()
    choose(first)
  end

  it("selects once, reuses one Terminal, and pins the current Agent by id", function()
    attach()
    local before = assert(terminal_state())
    assert.are.equal(1, #terminal_buffers())
    Pigeon.pick()
    assert.are.equal(first, choices[1])
    assert.are.equal("first [current]", options.format_item(first))
    choose(second)
    assert.are.same({ before.client }, second.retargets)
    local after = assert(terminal_state())
    assert.are.equal(before.buffer, after.buffer)
    assert.are.equal(before.job, after.job)
    Pigeon.show()
  end)

  it("installs configured action keymaps and fixes the Terminal buffer in its window", function()
    local inspected = false
    assert.is_true(Pigeon.setup({
      keymaps = { close = {}, inspect = { "<F2>" } },
      actions = {
        inspect = function()
          inspected = true
        end,
      },
    }))
    attach()
    local before = assert(terminal_state())
    local window = assert(vim.fn.win_findbuf(before.buffer)[1])
    assert.is_true(vim.wo[window].winfixbuf)
    assert.are.equal("", vim.fn.maparg("<C-.>", "t"))
    local mapping = vim.api.nvim_buf_call(before.buffer, function()
      return vim.fn.maparg("<F2>", "t", false, true)
    end)
    assert.are.equal(1, mapping.buffer)
    assert.are.equal(1, mapping.silent)
    mapping.callback()
    assert.is_true(inspected)
  end)

  it("sends through the current Agent without focusing or switching windows", function()
    attach()
    local window = vim.api.nvim_get_current_win()
    Pigeon.send(Message.reference("/a.lua"))
    assert.are.same({ { "first", "first:/a.lua" } }, delivered)
    assert.are.equal(window, vim.api.nvim_get_current_win())
    assert.are.same({}, notes)
  end)

  it("reports an unattached send and never falls back to a previous Agent", function()
    Pigeon.send(Message.text("text"))
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("no attached Agent", 1, true))
    assert.is_nil(choose)
    attach()
    local before = assert(terminal_state())
    vim.api.nvim_buf_delete(before.buffer, { force = true })
    assert(vim.wait(2000, function()
      return terminal_state() == nil
    end))
    Pigeon.send(Message.text("text"))
    assert.are.equal(2, #notes)
    assert.are.same({}, delivered)
  end)

  it("keeps the existing Agent on cancellation, discovery or retarget failure", function()
    attach()
    local before = assert(terminal_state())
    Pigeon.pick()
    choose(nil)
    fail = "list"
    Pigeon.pick()
    fail = "retarget"
    Pigeon.pick()
    choose(second)
    assert.are.equal(2, #notes)
    fail = nil
    Pigeon.send(Message.text("still first"))
    assert.are.same({ { "first", "first:still first" } }, delivered)
    assert.are.equal(before.buffer, terminal_state().buffer)
  end)

  it("does not deliver partial evaluation", function()
    attach()
    Pigeon.send(Message.join("\n", { Message.text("first"), Message.reference("") }))
    assert.are.same({}, delivered)
    assert.are.equal(1, #notes)
  end)

  it("prompts for a sole choice and preserves the Terminal across setup/status", function()
    choices = { first }
    Pigeon.show()
    assert.are.equal(1, #choices)
    assert.is_not_nil(choose)
    choose(first)
    assert.are.equal(1, #terminal_buffers())
    assert.are.same({ "pick", "send", "setup", "show", "status" }, vim.fn.sort(vim.tbl_keys(Pigeon)))
    assert.is_true(Pigeon.setup({ view = { width = 80 } }))
    Pigeon.status()
    assert.are.same({ "pigeon: agent: first" }, notes)
    Pigeon.send(Message.text("text"))
    assert.are.same({ { "first", "first:text" } }, delivered)
  end)

  it("cleans the Terminal synchronously when the attach job ends", function()
    attach()
    local before = assert(terminal_state())
    assert(vim.fn.jobstop(before.job) == 1)
    assert(vim.wait(2000, function()
      return terminal_state() == nil
    end))
    Pigeon.status()
    assert.are.same({ "pigeon: agent: not attached" }, notes)
    Pigeon.show()
    assert.is_not_nil(choose)
    choose(first)
    assert.are.equal(1, #terminal_buffers())
  end)

  it("clears state when an external deletion closes the buffer", function()
    attach()
    local before = assert(terminal_state())
    vim.api.nvim_buf_delete(before.buffer, { force = true })
    assert(vim.wait(2000, function()
      return terminal_state() == nil
    end))
    Pigeon.show()
    assert.is_not_nil(choose)
    choose(first)
    assert.are.equal(1, #terminal_buffers())
  end)

  it("rolls back creation when the attach job cannot start", function()
    local bad = agent("bad")
    bad.attach = function()
      return { "/pigeon-test-no-such-executable" }
    end
    choices = { bad }
    Pigeon.pick()
    assert.is_not_nil(choose)
    choose(bad)
    assert.are.equal(1, #notes)
    assert.are.equal(0, #terminal_buffers())
    choose = nil
    choices = { first, second }
    Pigeon.show()
    assert.are.equal(2, #choices)
    assert.is_not_nil(choose)
  end)
end)
