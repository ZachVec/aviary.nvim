---@module 'luassert'

local api = vim.api
local Async = require("aviary.shared.async")
local Git = require("aviary.hawk.git")
local Row = require("aviary.hawk.snapshot.row")
local hawk = require("aviary").hawk
local h = require("hawk.helpers")
local project = vim.fn.getcwd()

local function groups()
  return vim.fn.getcompletion("aviary.hawk.tab.", "augroup")
end

local function override(target, key, replacement, work)
  local original = target[key]
  target[key] = replacement
  local ok, reason = pcall(work)
  target[key] = original
  assert(ok, reason)
end

describe("Review transactional lifetime", function()
  local source, cwd, dir, tabs, buffers, diff, versions, notify, notes

  local function entry()
    return { root = dir, path = "a.txt", status = "M", kind = "text" }
  end

  before_each(function()
    source, cwd = api.nvim_get_current_win(), vim.fn.getcwd(-1, -1)
    dir = h.repo()
    h.write(dir, "a.txt", { "source" })
    h.commit(dir)
    h.edit(dir .. "/a.txt")
    vim.cmd.cd(dir)
    tabs, buffers = api.nvim_list_tabpages(), api.nvim_list_bufs()
    diff, versions, notify = Git.diff, Git.versions, vim.notify
    notes = {}
    Git.diff = function()
      return { entry() }
    end
    Git.versions = function()
      return { old = "old\n", new = "new\n" }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
  end)

  after_each(function()
    vim.cmd.cd(cwd)
    h.cleanup(source, dir)
    h.flush()
    Git.diff, Git.versions, vim.notify = diff, versions, notify
  end)

  for _, field in ipairs({ "bottom_win", "old_win", "new_win", "bufnr", "old_buf", "new_buf" }) do
    it("ends when owned " .. field .. " closes or wipes", function()
      local tab, bottom = h.open()
      Row.diff(entry()):jump(tab)
      api.nvim_set_current_win(source)
      if field:match("buf") then
        api.nvim_buf_delete(tab[field], { force = true })
      else
        api.nvim_win_close(field == "bottom_win" and bottom or tab[field], true)
      end
      assert.are.same({}, groups())
      for _, win in ipairs({ tab.old_win, tab.new_win }) do
        if api.nvim_win_is_valid(win) then
          assert.is_false(vim.wo[win].diff)
          assert.is_false(vim.wo[win].winfixbuf)
        end
      end
      h.flush()
      assert.are.same(tabs, api.nvim_list_tabpages())
      assert.are.same(buffers, api.nvim_list_bufs())
      assert.are.same({}, notes)
    end)
  end

  it("ends on forced preview replacement and leaves another review usable", function()
    local first = h.open()
    Row.diff(entry()):jump(first)
    api.nvim_win_call(first.old_win, function()
      vim.cmd("enew!")
    end)
    assert.is_false(api.nvim_buf_is_valid(first.old_buf))
    local second = h.open()
    Row.diff(entry()):jump(second)
    assert.are.same({ "new" }, h.lines(second.new_buf))
    assert.are.equal(1, #groups())
    assert.are.same({}, notes)
  end)

  it("keeps preview work independent from refresh and cancels superseded selections", function()
    local tab = h.open()
    h.edit_input(1, "main")
    h.edit_input(2, "topic")
    local selected = Row.diff(entry())
    local jobs, stops, delivered = {}, {}, 0
    override(vim.fn, "jobstart", function(_, opts)
      jobs[#jobs + 1] = opts
      return 122 + #jobs
    end, function()
      override(vim.fn, "jobstop", function(jid)
        stops[#stops + 1] = jid
        return 1
      end, function()
        override(Git, "versions", function(ctx)
          Async({ "body" }):run(ctx):wait()
          delivered = delivered + 1
          return { old = "late old", new = "late new" }
        end, function()
          selected:jump(tab)
          tab:refresh()
          assert.are.same({}, stops)
          assert.are.equal(0, delivered)
          selected:jump(tab)
          assert.are.same({ 123 }, stops)
          jobs[1].on_exit(123, 143)
          vim.cmd.close()
          assert.are.same({ 123, 124 }, stops)
          jobs[2].on_exit(124, 143)
          h.flush()
          assert.are.equal(0, delivered)
          assert.are.same({}, notes)
        end)
      end)
    end)
  end)

  it("uses the two rename paths for names and filetypes and starts previews at the top", function()
    local tab, bottom = h.open()
    local selected = Row.diff({
      root = dir,
      status = "R",
      kind = "text",
      old_path = "old\tname.lua",
      path = "new\nname.py",
    })
    local lines = string.rep("line\n", 20)
    override(Git, "versions", function()
      return { old = lines, new = lines .. "extra\n" }
    end, function()
      selected:jump(tab)
      api.nvim_win_set_cursor(tab.old_win, { 12, 1 })
      api.nvim_win_set_cursor(tab.new_win, { 13, 1 })
      selected:jump(tab)
    end)
    assert.matches(("%d:old/old name%%.lua$"):format(tab.tabpage), api.nvim_buf_get_name(tab.old_buf))
    assert.matches(("%d:new/new name%%.py$"):format(tab.tabpage), api.nvim_buf_get_name(tab.new_buf))
    assert.are.equal("lua", vim.bo[tab.old_buf].filetype)
    assert.are.equal("python", vim.bo[tab.new_buf].filetype)
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(tab.old_win))
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(tab.new_win))
    assert.are.equal(bottom, api.nvim_get_current_win())
    assert.are.same({}, notes)
  end)

  it("cancels both Git blob reads when an owned window closes", function()
    local tab = h.open()
    local jobs, stops = {}, {}
    local selected = Row.diff(vim.tbl_extend("force", entry(), { old_blob = "old-oid", new_blob = "new-oid" }))
    override(vim.fn, "jobstart", function(_, opts)
      jobs[#jobs + 1] = opts
      return 122 + #jobs
    end, function()
      override(vim.fn, "jobstop", function(jid)
        stops[#stops + 1] = jid
        return 1
      end, function()
        override(Git, "versions", versions, function()
          selected:jump(tab)
          assert.are.equal(2, #jobs)
          api.nvim_win_close(tab.old_win, true)
          table.sort(stops)
          assert.are.same({ 123, 124 }, stops)
          for index, opts in ipairs(jobs) do
            opts.on_stdout(122 + index, { "late" })
            opts.on_exit(122 + index, 143)
          end
          h.flush()
          assert.are.same({}, notes)
        end)
      end)
    end)
  end)

  it("cancels merge-base work before it can start the diff", function()
    local tab = h.open()
    tab:to("merge")
    h.edit_input(1, "main")
    h.edit_input(2, "topic")
    local callback, stopped
    override(vim.fn, "jobstart", function(argv, opts)
      assert.is_nil(callback)
      assert.is_true(vim.tbl_contains(argv, "merge-base"))
      callback = opts
      return 123
    end, function()
      override(vim.fn, "jobstop", function(id)
        stopped = id
        return 1
      end, function()
        tab:refresh()
        assert.is_not_nil(callback)
        tab:to("direct")
        assert.are.equal(123, stopped)
        callback.on_stdout(123, { string.rep("a", 40), "" })
        callback.on_exit(123, 143)
        h.flush()
        assert.are.same({ "main", "topic" }, h.lines(tab.bufnr))
        assert.are.same({}, notes)
      end)
    end)
  end)

  it("uses native qall with unsaved checks, confirmation and cancellation", function()
    for _, scenario in ipairs({ "last", "refused", "confirm", "cancel" }) do
      local result = vim
        .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/hawk/close_driver.lua", scenario }, {
          text = true,
          cwd = project,
        })
        :wait(10000)
      assert.are.equal(0, result.code, result.stderr)
      if scenario == "refused" then
        assert.matches("E37", result.stderr)
      elseif scenario == "last" then
        assert.are.equal("", result.stderr)
      else
        assert.is_nil(result.stderr:find("vim.schedule", 1, true))
      end
      assert.are.equal("checked\n", result.stdout)
    end
  end)

  it("rolls back when native columns cannot fit the layout", function()
    local size, minimum = vim.o.winwidth, vim.o.winminwidth
    vim.o.winwidth = vim.o.columns
    vim.o.winminwidth = math.floor(vim.o.columns / 2) + 1
    local ok, reason = pcall(hawk.show)
    vim.o.winminwidth = minimum
    vim.o.winwidth = size
    assert.is_false(ok)
    assert.matches("E36", tostring(reason))
    assert.are.equal(source, api.nvim_get_current_win())
    assert.are.same(tabs, api.nvim_list_tabpages())
    assert.are.same(buffers, api.nvim_list_bufs())
    assert.are.same({}, groups())
  end)

  it("rolls back when native rows cannot fit the layout", function()
    local size, minimum = vim.o.winheight, vim.o.winminheight
    vim.o.winheight = vim.o.lines
    vim.o.winminheight = math.floor(vim.o.lines / 2) + 1
    local ok, reason = pcall(hawk.show)
    vim.o.winminheight = minimum
    vim.o.winheight = size
    assert.is_false(ok)
    assert.matches("E36", tostring(reason))
    assert.are.equal(source, api.nvim_get_current_win())
    assert.are.same(tabs, api.nvim_list_tabpages())
    assert.are.same(buffers, api.nvim_list_bufs())
    assert.are.same({}, groups())
  end)
end)
