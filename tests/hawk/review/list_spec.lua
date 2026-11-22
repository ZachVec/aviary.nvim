---@module 'luassert'

local api = vim.api
local Async = require("aviary.shared.async")
local Config = require("aviary.hawk.config")
local Git = require("aviary.hawk.git")
local h = require("hawk.helpers")

describe("Review list", function()
  local source, cwd, dir, requests, notes, read, notify, jobstart, jobstop

  local function entry(path)
    return { root = dir, path = path, status = "M", kind = "text", added = 3, removed = 2 }
  end

  local function open()
    local tab, bottom = h.open()
    h.edit_input(1, "main")
    h.edit_input(2, "topic")
    tab:refresh()
    return tab, bottom
  end

  local function ready(entries)
    requests[#requests].deliver(entries)
    h.flush()
  end

  before_each(function()
    source, cwd = api.nvim_get_current_win(), vim.fn.getcwd(-1, -1)
    dir = h.repo()
    vim.cmd.cd(dir)
    requests, notes = {}, {}
    read, notify, jobstart, jobstop = Git.diff, vim.notify, vim.fn.jobstart, vim.fn.jobstop
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    Git.diff = function(ctx, _, old, new)
      local request = { old = old, new = new, cancelled = false }
      requests[#requests + 1] = request
      Async({ "hawk-list-spec" }):run(ctx):wait()
      if request.failure then
        error(request.failure, 0)
      end
      return request.entries
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(argv, options)
      assert.are.equal("hawk-list-spec", argv[1])
      local id = #requests
      local request = requests[id]
      request.deliver = function(entries, reason)
        request.entries, request.failure = entries, reason
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
    vim.cmd.cd(cwd)
    h.cleanup(source, dir)
    h.flush()
    Git.diff, vim.notify, vim.fn.jobstart, vim.fn.jobstop = read, notify, jobstart, jobstop
    Config.setup()
  end)

  it("maps buffer rows to metadata and the captured diff entries", function()
    local tab, bottom = open()
    local item = entry("current")
    ready({ item })
    assert.are.same({ "main", "topic", "  M current +3 -2" }, h.lines(tab.bufnr))
    api.nvim_win_set_cursor(bottom, { 1, 0 })
    local draft, draft_line = tab:current()
    assert.are.equal("meta", draft.kind)
    assert.are.equal(1, draft_line)
    api.nvim_win_set_cursor(bottom, { 3, 0 })
    local row, row_line = tab:current()
    assert.are.equal("diff", row.kind)
    assert.are.equal(item, row)
    assert.are.equal(3, row_line)
  end)

  it("keeps the cursor on a valid row when the change list shrinks or becomes empty", function()
    local tab, bottom = open()
    ready({ entry("first"), entry("second"), entry(string.rep("x", 60)) })
    api.nvim_win_set_cursor(bottom, { 5, 40 })
    tab:refresh()
    ready({ entry("xy") })
    assert.are.equal(3, api.nvim_win_get_cursor(bottom)[1])
    tab:refresh()
    ready({})
    assert.are.equal(2, api.nvim_win_get_cursor(bottom)[1])
    assert.are.same({ "main", "topic" }, h.lines(tab.bufnr))
  end)

  it("cancels superseded queries and keeps the last result when a later query fails", function()
    local tab = open()
    requests[1].deliver({ entry("obsolete") })
    tab:refresh()
    h.flush()
    assert.is_true(requests[1].cancelled)
    assert.are.same({ "main", "topic" }, h.lines(tab.bufnr))
    ready({ entry("latest") })
    tab:refresh()
    requests[3].deliver(nil, "failed refresh")
    h.flush()
    assert.are.same({ "main", "topic", "  M latest +3 -2" }, h.lines(tab.bufnr))
    assert.are.equal(1, #notes)
    assert.matches("failed refresh", notes[1])
  end)

  it("publishes submitted revisions when a draft is edited while the query is pending", function()
    local tab = open()
    h.edit_input(2, "next")
    ready({ entry("submitted") })
    assert.are.same({ "main", "next", "  M submitted +3 -2" }, h.lines(tab.bufnr))
    assert.matches("main   topic$", vim.fn.bufname(tab.bufnr))
    assert.are.equal("topic", requests[1].new)
  end)

  it("preserves pending work on skipped refresh and cancels it on a mode change", function()
    local tab = open()
    h.edit_input(1, "")
    h.press("r")
    assert.are.equal(1, #requests)
    assert.is_false(requests[1].cancelled)
    tab:to("direct")
    assert.is_false(requests[1].cancelled)
    tab:to("merge")
    assert.is_true(requests[1].cancelled)
    requests[1].deliver({ entry("obsolete") })
    h.flush()
    assert.are.same({ " ", "topic" }, h.lines(tab.bufnr))
    assert.matches("󰓁$", vim.fn.bufname(tab.bufnr))
  end)

  it("clears queued normal mappings on close and preserves mappings in other modes", function()
    Config.setup({ keymaps = { refresh = { "r", "<F6>" } } })
    local tab = open()
    local modes = { "x", "i" }
    vim.keymap.set(modes, "<F7>", "<Nop>", { buffer = tab.bufnr })
    vim.keymap.set("n", "<F7>", "<Nop>", { buffer = tab.new_buf })
    api.nvim_set_current_win(tab.old_win)
    api.nvim_feedkeys(vim.keycode("<C-w>c<C-w>b<F6>"), "xt", false)
    assert.is_true(api.nvim_tabpage_is_valid(tab.tabpage))
    assert.is_true(api.nvim_buf_is_valid(tab.bufnr))
    assert.are.equal(tab.bufnr, api.nvim_get_current_buf())
    assert.are.same({}, api.nvim_buf_get_keymap(tab.bufnr, "n"))
    for _, mode in ipairs(modes) do
      assert.are.equal("<F7>", api.nvim_buf_get_keymap(tab.bufnr, mode)[1].lhs)
    end
    assert.are.equal("<F7>", api.nvim_buf_get_keymap(tab.new_buf, "n")[1].lhs)
    assert.is_true(requests[1].cancelled)
    h.flush()
    assert.are.equal(1, #requests)
    assert.is_false(api.nvim_buf_is_valid(tab.bufnr))
  end)

  it("draws byte ranges for non-ASCII paths and preserves the input extmarks on refresh", function()
    local tab = open()
    local namespaces = api.nvim_get_namespaces()
    local labels = api.nvim_buf_get_extmarks(tab.bufnr, namespaces["aviary.hawk.tab.label"], 0, -1, {})
    ready({ entry("中文.txt") })
    local spans = {}
    local value_ns = namespaces["aviary.hawk.tab.value"]
    for _, mark in ipairs(api.nvim_buf_get_extmarks(tab.bufnr, value_ns, 0, -1, { details = true })) do
      spans[#spans + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
    end
    assert.are.same({
      { 2, 2, 3, "Changed" },
      { 2, 4, 14, "Directory" },
      { 2, 15, 17, "Added" },
      { 2, 18, 20, "Removed" },
    }, spans)
    assert.are.same(labels, api.nvim_buf_get_extmarks(tab.bufnr, namespaces["aviary.hawk.tab.label"], 0, -1, {}))
  end)

  it("refreshes its own list after focus changes and cancels late failures on closure", function()
    local tab = open()
    local refresh = vim.fn.maparg("r", "n", false, true).callback
    api.nvim_set_current_win(source)
    refresh()
    h.flush()
    assert.are.equal(source, api.nvim_get_current_win())
    assert.are.equal(2, #requests)
    assert.is_true(requests[1].cancelled)
    requests[2].deliver(nil, "obsolete failure")
    api.nvim_win_close(tab.old_win, true)
    assert.is_true(requests[2].cancelled)
    h.flush()
    assert.are.same({}, notes)
  end)

  it("keeps source locks and gives all three owned windows their own buffer locks", function()
    local options = {}
    for _, key in ipairs({ "winfixbuf", "winfixheight", "winfixwidth" }) do
      options[key] = vim.wo[source][key]
      vim.wo[source][key] = true
    end
    local ok, reason = pcall(function()
      local tab = h.open()
      for _, win in ipairs(api.nvim_tabpage_list_wins(tab.tabpage)) do
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
