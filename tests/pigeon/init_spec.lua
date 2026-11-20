---@module 'luassert'
---@diagnostic disable: duplicate-set-field
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")

describe("aviary.pigeon Terminal routing", function()
  local Pigeon, Backends, choices, choose, options, delivered, notes, fail
  local saved_select, saved_notify
  local first, second
  local original_buf, original_win, extra_bufs, extra_paths

  local function agent(name)
    local self = {
      retargets = {},
      eval = function(_, reference)
        local text = reference.path
        if reference.start_row then
          text = text .. ":" .. reference.start_row
          if reference.end_row and reference.end_row ~= reference.start_row then
            text = text .. "-" .. reference.end_row
          end
        end
        return name .. ":" .. text
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
  local function edit_named(lines)
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile(lines, path)
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    vim.cmd.edit(path)
    extra_paths[#extra_paths + 1] = path
    extra_bufs[#extra_bufs + 1] = vim.api.nvim_get_current_buf()
    return path
  end
  local function mapping(buffer, lhs)
    return vim.api.nvim_buf_call(buffer, function()
      return vim.fn.maparg(lhs, "t", false, true)
    end)
  end
  before_each(function()
    original_buf, original_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    extra_bufs, extra_paths = {}, {}
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
    vim.cmd("normal! \27")
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
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    if vim.api.nvim_buf_is_valid(original_buf) then
      vim.api.nvim_set_current_buf(original_buf)
    end
    for _, buffer in ipairs(extra_bufs) do
      if vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    for _, path in ipairs(extra_paths) do
      vim.fn.delete(path)
    end
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

  it("installs configured action keymaps with the Terminal and passes the captured reference", function()
    local inspected
    assert.is_true(Pigeon.setup({
      keymaps = { close = {}, inspect = { "<F2>" } },
      actions = {
        inspect = function(target, reference)
          inspected = { agent = target, reference = reference }
        end,
      },
    }))
    local path = edit_named({ "one", "two", "three" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    attach()
    local before = assert(terminal_state())
    local window = assert(vim.fn.win_findbuf(before.buffer)[1])
    assert.is_true(vim.wo[window].winfixbuf)
    assert.are.equal("", vim.fn.maparg("<C-.>", "t"))
    local map = mapping(before.buffer, "<F2>")
    assert.are.equal(1, map.buffer)
    assert.are.equal(1, map.silent)
    map.callback()
    assert.are.equal(first, inspected.agent)
    assert.are.equal(path, inspected.reference.path)
    assert.are.equal(2, inspected.reference.start_row)
    assert.is_nil(inspected.reference.end_row)
  end)

  it("runs actions without focusing or switching windows", function()
    Pigeon.setup({
      keymaps = { send = { "<F3>" } },
      actions = {
        send = function(target)
          target:send("payload")
        end,
      },
    })
    attach()
    local before = assert(terminal_state())
    local window = vim.api.nvim_get_current_win()
    mapping(before.buffer, "<F3>").callback()
    assert.are.same({ { "first", "payload" } }, delivered)
    assert.are.equal(window, vim.api.nvim_get_current_win())
    assert.are.same({}, notes)
  end)

  it("lets Terminal-buffer actions reach the terminal job without the Terminal", function()
    local captured
    Pigeon.setup({
      keymaps = { job = { "<F4>" } },
      actions = {
        job = function()
          captured = vim.b.terminal_job_id
        end,
      },
    })
    attach()
    local before = assert(terminal_state())
    vim.api.nvim_buf_call(before.buffer, function()
      mapping(before.buffer, "<F4>").callback()
    end)
    assert.are.equal(before.job, captured)
  end)

  it("preserves the captured reference when show is invoked from the Terminal", function()
    local inspected
    Pigeon.setup({
      keymaps = { inspect = { "<F2>" } },
      actions = {
        inspect = function(_, reference)
          inspected = reference
        end,
      },
    })
    local path = edit_named({ "one", "two" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    attach()
    Pigeon.show()
    local before = assert(terminal_state())
    mapping(before.buffer, "<F2>").callback()
    assert.are.equal(path, inspected.path)
    assert.are.equal(2, inspected.start_row)
  end)

  it("captures a Visual range when show is invoked and exits Visual", function()
    local inspected
    Pigeon.setup({
      keymaps = { inspect = { "<F2>" } },
      actions = {
        inspect = function(_, reference)
          inspected = reference
        end,
      },
    })
    attach()
    local path = edit_named({ "one", "two", "three", "four" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! Vj")
    assert.are.equal("V", vim.api.nvim_get_mode().mode)
    Pigeon.show()
    local mode = vim.api.nvim_get_mode().mode
    assert.is_nil(mode:match("[vV\22]"))
    assert.is_truthy(mode:find("n", 1, true))
    local before = assert(terminal_state())
    mapping(before.buffer, "<F2>").callback()
    assert.are.equal(path, inspected.path)
    assert.are.equal(2, inspected.start_row)
    assert.are.equal(3, inspected.end_row)
  end)

  it("keeps the existing Agent on cancellation, discovery or retarget failure", function()
    Pigeon.setup({
      keymaps = { send = { "<F3>" } },
      actions = {
        send = function(target)
          target:send("still first")
        end,
      },
    })
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
    mapping(before.buffer, "<F3>").callback()
    assert.are.same({ { "first", "still first" } }, delivered)
    assert.are.equal(before.buffer, terminal_state().buffer)
  end)

  it("prompts for a sole choice and preserves the Terminal across setup/status", function()
    choices = { first }
    Pigeon.show()
    assert.are.equal(1, #choices)
    assert.is_not_nil(choose)
    choose(first)
    assert.are.equal(1, #terminal_buffers())
    assert.are.same({ "pick", "setup", "show", "status" }, vim.fn.sort(vim.tbl_keys(Pigeon)))
    assert.is_nil(Pigeon.send)
    assert.is_true(Pigeon.setup({ view = { width = 80 } }))
    Pigeon.status()
    assert.are.same({ "pigeon: agent: first" }, notes)
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
