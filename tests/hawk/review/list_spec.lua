---@module 'luassert'

local Async = require("aviary.shared.async")
local Config = require("aviary.hawk.config")
local Data = require("aviary.hawk.review.review")
local Review = require("aviary.hawk.review")
local h = require("hawk.helpers")

local function item(text, number)
  return {
    text = text,
    render = function(self)
      local value = self.text .. "  " .. (number or "3")
      return { text = value, highlights = { { start_col = 0, end_col = #self.text, hl = "Normal" } } }
    end,
  }
end

local function snapshot(text)
  return { items = text == "" and {} or { item(text) } }
end

local function list_events()
  return vim.tbl_filter(function(event)
    return (event.group_name or ""):match("^aviary%.hawk%.review%.tab%.") ~= nil
  end, vim.api.nvim_get_autocmds({}))
end

-- Use the concrete Review and real async flow; control only its data query jobs.
describe("Review list", function()
  local source, requests, notes, closed, stopped, read, start, notify, jobstart, jobstop
  ---@type any native resource inspection
  local tab

  local function on_close()
    closed = closed + 1
  end
  local function changed()
    vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
  end
  local function open()
    tab = Review.create(on_close)
    ---@cast tab any native resource inspection
    h.flush()
    return vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
  end
  local function ready(text)
    requests[#requests].deliver(snapshot(text))
    h.flush()
  end

  before_each(function()
    source = vim.api.nvim_get_current_win()
    requests, notes, closed, stopped, tab = {}, {}, 0, 0, nil
    read, start, notify, jobstart, jobstop = Data.read, Data.start, vim.notify, vim.fn.jobstart, vim.fn.jobstop
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    Data.start = function()
      return function()
        stopped = stopped + 1
      end
    end
    Data.read = function(ctx)
      local request = { cancelled = false }
      requests[#requests + 1] = request
      Async({ "hawk-list-spec" }):run(ctx):wait()
      if request.failure then
        error(request.failure, 0)
      end
      return request.items, nil
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(argv, options)
      assert.are.equal("hawk-list-spec", argv[1])
      local id = #requests
      local request = requests[id]
      request.deliver = function(value, reason)
        request.items, request.failure = value and value.items, reason
        vim.schedule(function()
          options.on_exit(id, 0)
        end)
      end
      return id
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstop = function(id)
      requests[id].cancelled = true
      return 1
    end
    Config.setup()
  end)
  after_each(function()
    vim.api.nvim_set_current_win(source)
    vim.cmd("silent! tabonly!")
    h.flush()
    Data.read, Data.start, vim.notify, vim.fn.jobstart, vim.fn.jobstop = read, start, notify, jobstart, jobstop
    Config.setup()
  end)

  it("renders current fields while actions retrieve the same original item", function()
    local _, buf = open()
    local value = snapshot("captured")
    value.items[1].text = "current"
    requests[#requests].deliver(value)
    h.flush()
    assert.are.same({ "current  3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(value.items[1] == tab:current())
    assert.are.equal("current", tab:current().text)
    changed()
    h.flush()
    value.items[1].text = "refreshed"
    requests[#requests].deliver(value)
    h.flush()
    assert.are.same({ "refreshed  3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("rerenders current items only when the text-area width changes without reloading", function()
    local _, buf = open()
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].number = true
    vim.wo[win].numberwidth = 4
    vim.wo[win].signcolumn = "yes"
    local widths = {}
    local value = snapshot("before")
    value.items[1].render = function(self, width)
      widths[#widths + 1] = width
      return { text = self.text, highlights = {} }
    end
    requests[1].deliver(value)
    h.flush()
    local info = vim.fn.getwininfo(win)[1]
    assert.are.same({ info.width - info.textoff }, widths)
    assert.is_true(widths[1] < vim.api.nvim_win_get_width(win))
    vim.api.nvim_win_set_height(win, vim.api.nvim_win_get_height(win) - 1)
    vim.api.nvim_exec_autocmds("WinResized", {})
    h.flush()
    assert.are.equal(1, #widths)

    value.items[1].text = "after"
    -- A real split changes window geometry even in the headless -l test runner.
    vim.cmd("noautocmd rightbelow vsplit")
    vim.api.nvim_exec_autocmds("WinResized", {})
    h.flush()
    assert.are.equal(2, #widths)
    info = vim.fn.getwininfo(win)[1]
    assert.are.equal(info.width - info.textoff, widths[2])
    assert.is_true(widths[2] < widths[1])
    assert.are.same({ "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert.are.equal(2, #widths)
    assert.are.equal(1, #requests)
    assert.is_false(requests[1].cancelled)
  end)

  it("rerenders after gutter changes at the same outer width and releases width listeners", function()
    local native, buf = open()
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    local widths = {}
    local value = snapshot("visible")
    value.items[1].render = function(_, width)
      widths[#widths + 1] = width
      return { text = tostring(width), highlights = {} }
    end
    requests[1].deliver(value)
    h.flush()
    local outer = vim.api.nvim_win_get_width(win)
    vim.wo[win].signcolumn = "yes"
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "signcolumn" })
    h.flush()
    assert.are.equal(outer, vim.api.nvim_win_get_width(win))
    assert.are.equal(2, #widths)
    assert.are.equal(widths[1] - 2, widths[2])
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "signcolumn" })
    assert.are.equal(2, #widths)
    assert.are.equal(1, #requests)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_exec_autocmds("WinResized", {})
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "signcolumn" })
    h.flush()
    assert.are.equal(2, #widths)
    assert.is_false(vim.api.nvim_tabpage_is_valid(native))
    assert.are.same({}, list_events())
  end)

  it("renders the available text width as the number column grows and shrinks", function()
    local _, buf = open()
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].number = true
    vim.wo[win].relativenumber = true
    vim.wo[win].numberwidth = 1
    vim.wo[win].signcolumn = "no"
    vim.wo[win].statuscolumn = ""
    for index, count in ipairs({ 99, 100, 101, 9, 0 }) do
      if index > 1 then
        changed()
        h.flush()
      end
      local value = snapshot("")
      for _ = 1, count do
        value.items[#value.items + 1] = {
          render = function(_, width)
            return { text = tostring(width), highlights = {} }
          end,
        }
      end
      requests[index].deliver(value)
      h.flush()
      assert.are.equal(math.max(1, count), vim.api.nvim_buf_line_count(buf))
      if count > 0 then
        local info = vim.fn.getwininfo(win)[1]
        assert.are.equal(tostring(info.width - info.textoff), vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      end
      assert.are.equal(index, #requests)
    end
  end)

  it("restores a valid cursor when refreshed rows shrink or become empty", function()
    open()
    local value = snapshot(string.rep("x", 60))
    value.items = { item("first", "1"), item("second", "2"), value.items[1] }
    requests[#requests].deliver(value)
    h.flush()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { 3, 40 })
    changed()
    h.flush()
    ready("xy")
    assert.are.same({ 1, 4 }, vim.api.nvim_win_get_cursor(win))
    changed()
    h.flush()
    ready("")
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("cancels queued results immediately and coalesces refresh notifications", function()
    local _, buf = open()
    requests[1].deliver(snapshot("obsolete"))
    changed()
    changed()
    changed()
    h.flush()
    assert.is_true(requests[1].cancelled)
    assert.are.equal(2, #requests)
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    ready("latest")
    changed()
    h.flush()
    requests[3].deliver(nil, "failed refresh")
    h.flush()
    assert.are.same({ "latest  3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(1, #notes)
  end)

  it("clears normal mappings before queued keys can restart reads and preserves other modes", function()
    Config.setup({ keymaps = { refresh = { "r", "<F6>" } } })
    local native, buf = open()
    local body = { tab.old_win, tab.new_win }
    local modes = { "x", "s", "o", "i", "c", "l", "t" }
    vim.keymap.set(modes, "<F7>", "<Nop>", { buffer = buf })
    local other = vim.api.nvim_win_get_buf(body[2])
    vim.keymap.set("n", "<F7>", "<Nop>", { buffer = other })
    vim.api.nvim_set_current_win(body[1])
    local keys = vim.api.nvim_replace_termcodes("<C-w>c<C-w>b<F6>", true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
    assert.are.equal(1, closed)
    assert.is_true(vim.api.nvim_tabpage_is_valid(native))
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.same({}, vim.api.nvim_buf_get_keymap(buf, "n"))
    for _, mode in ipairs(modes) do
      assert.are.equal("<F7>", vim.api.nvim_buf_get_keymap(buf, mode)[1].lhs)
    end
    assert.are.equal("<F7>", vim.api.nvim_buf_get_keymap(other, "n")[1].lhs)
    assert.is_true(requests[1].cancelled)
    h.flush()
    assert.are.equal(1, #requests)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("cancels a queued refresh when the bottom wipes before reload starts", function()
    tab = Review.create(on_close)
    ---@cast tab any native resource inspection
    local bottom = vim.api.nvim_get_current_win()
    assert.are.equal(0, #requests)
    vim.api.nvim_win_close(bottom, false)
    assert.are.equal(1, closed)
    h.flush()
    assert.are.equal(0, #requests)
  end)

  it("keeps initial read failures retryable and reports them", function()
    local _, buf = open()
    requests[1].deliver(nil, "unavailable")
    h.flush()
    assert.are.equal(1, #notes)
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    h.press("r")
    h.flush()
    ready("retried")
    assert.are.same({ "retried  3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("installs item byte ranges on their rows and skips default or empty highlights", function()
    local _, buf = open()
    requests[1].deliver({
      name = "aviary://test/padding",
      items = {
        {
          render = function()
            return {
              text = "中      7",
              highlights = {
                { start_col = 0, end_col = 3, hl = "Normal" },
                { start_col = 3, end_col = 9 },
                { start_col = 9, end_col = 10, hl = "Number" },
                { start_col = 10, end_col = 10, hl = "Normal" },
              },
            }
          end,
        },
        {
          render = function()
            return {
              text = "abcd  123",
              highlights = {
                { start_col = 0, end_col = 4, hl = "Normal" },
                { start_col = 6, end_col = 9, hl = "Number" },
              },
            }
          end,
        },
      },
    })
    h.flush()
    assert.are.same({ "中      7", "abcd  123" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local spans = {}
    local namespace = vim.api.nvim_create_namespace("aviary.hawk.review.list")
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
      spans[#spans + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
    end
    assert.are.same({
      { 0, 0, 3, "Normal" },
      { 0, 9, 10, "Number" },
      { 1, 0, 4, "Normal" },
      { 1, 6, 9, "Number" },
    }, spans)
  end)

  it("ignores ordinary tab closure and handles renumbering", function()
    local native = open()
    vim.cmd("0tabnew")
    vim.cmd.tabclose()
    h.flush()
    assert.is_true(vim.api.nvim_tabpage_is_valid(native))
    tab:focus()
    h.press("q")
    h.flush()
    assert.is_false(vim.api.nvim_tabpage_is_valid(native))
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.is_false(vim.wo.winfixbuf)
    assert.is_false(vim.wo.winfixheight)
    assert.is_false(vim.wo.winfixwidth)
  end)

  it("installs the list before observation and coalesces inline creation notifications", function()
    local initialized = false
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "aviary_hawk",
      once = true,
      nested = true,
      callback = function(event)
        initialized = true
        assert.are.equal("wipe", vim.bo[event.buf].bufhidden)
        assert.is_false(vim.bo[event.buf].modifiable)
        assert.are.same({}, vim.api.nvim_buf_get_keymap(event.buf, "n"))
        vim.api.nvim_exec_autocmds("WinResized", {})
        vim.api.nvim_exec_autocmds("OptionSet", { pattern = "number" })
      end,
    })
    Data.start = function()
      assert.is_true(initialized)
      changed()
      changed()
      return function()
        stopped = stopped + 1
      end
    end
    tab = Review.create(on_close)
    ---@cast tab any native resource inspection
    assert.are.equal(0, #requests)
    h.flush()
    assert.are.equal(1, #requests)
    assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(tab.winnr))
    assert.is_false(vim.wo[tab.winnr].winfixheight)
    vim.api.nvim_buf_delete(tab.bufnr, { force = true })
    assert.is_true(requests[1].cancelled)
    assert.are.equal(1, closed)
    assert.are.equal(1, stopped)
  end)

  it("refreshes its own list after focus changes and cancels late failures on closure", function()
    open()
    local refresh = vim.fn.maparg("r", "n", false, true).callback
    vim.api.nvim_set_current_win(source)
    refresh()
    h.flush()
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.equal(2, #requests)
    assert.is_true(requests[1].cancelled)
    requests[2].deliver(nil, "obsolete failure")
    vim.api.nvim_win_close(tab.old_win, true)
    assert.is_true(requests[2].cancelled)
    h.flush()
    assert.are.same({}, notes)
    assert.are.equal(1, closed)
  end)

  it("keeps source locks and gives all three owned windows their own buffer locks", function()
    local options = {}
    for _, key in ipairs({ "winfixbuf", "winfixheight", "winfixwidth" }) do
      options[key] = vim.wo[source][key]
      vim.wo[source][key] = true
    end
    local ok, reason = pcall(function()
      open()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        assert.is_true(vim.wo[win].winfixbuf)
        assert.is_false(vim.wo[win].winfixheight)
        assert.is_false(vim.wo[win].winfixwidth)
      end
      for key in pairs(options) do
        assert.is_true(vim.wo[source][key])
      end
    end)
    for key, value in pairs(options) do
      vim.wo[source][key] = value
    end
    assert(ok, reason)
  end)
end)
