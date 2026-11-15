---@module 'luassert'

local Async = require("aviary.shared.async")
local Review = require("aviary.hawk.review")
local ReviewData = require("aviary.hawk.review.review")
local h = require("hawk.helpers")
local project = vim.fn.getcwd()

local function groups()
  return vim.fn.getcompletion("aviary.hawk.review.tab.", "augroup")
end

local function override(target, key, replacement, work)
  local original = target[key]
  target[key] = replacement
  local results = { pcall(work) }
  target[key] = original
  assert(results[1], results[2])
  return unpack(results, 2)
end

describe("Review transactional lifetime", function()
  local source, cwd, dir, tabs, buffers, read, text, start, notify, notes, closed, stopped, reads
  local item = {
    root = "",
    base = "HEAD",
    target = "index",
    path = "a.txt",
    status = "M",
    kind = "text",
    render = function()
      return { text = "a.txt", highlights = {} }
    end,
  }
  before_each(function()
    source, cwd = vim.api.nvim_get_current_win(), vim.fn.getcwd(-1, -1)
    dir = h.repo()
    h.write(dir, "a.txt", { "source" })
    h.commit(dir)
    h.edit(dir .. "/a.txt")
    vim.cmd.cd(dir)
    tabs, buffers = vim.api.nvim_list_tabpages(), vim.api.nvim_list_bufs()
    read, text, start, notify = ReviewData.read, ReviewData.text, ReviewData.start, vim.notify
    notes, closed, stopped, reads = {}, 0, 0, 0
    item.root = dir
    ReviewData.read = function()
      reads = reads + 1
      return { item }, "HEAD"
    end
    ReviewData.text = function()
      return { old = "old\n", new = "new\n" }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    ReviewData.start = function()
      vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
      return function()
        stopped = stopped + 1
      end
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
  end)
  after_each(function()
    h.cleanup(source, dir)
    h.flush()
    vim.cmd.cd(cwd)
    ReviewData.read, ReviewData.text, ReviewData.start, vim.notify = read, text, start, notify
  end)
  local function on_close()
    closed = closed + 1
  end
  local function rollback(ok, reason)
    assert.is_false(ok)
    assert.matches("acquisition failed", tostring(reason))
    h.flush()
    assert.are.equal(0, closed)
    assert.are.equal(0, reads)
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.same({}, groups())
  end

  it("rolls back the UI when watch startup raises", function()
    override(ReviewData, "start", function()
      error("watch acquisition failed", 0)
    end, function()
      rollback(pcall(Review.create, on_close))
    end)
  end)

  it("removes the directory observer when later lifecycle registration fails", function()
    local events = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    local create = vim.api.nvim_create_autocmd
    override(ReviewData, "start", start, function()
      override(vim.api, "nvim_create_autocmd", function(event, opts)
        if event == "BufWipeout" then
          error("lifecycle acquisition failed", 0)
        end
        return create(event, opts)
      end, function()
        rollback(pcall(Review.create, on_close))
      end)
    end)
    assert.are.same(events, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
  end)

  it(
    "releases native watches, debounce and directory observation on UI closure and recreates them on reopen",
    function()
      local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
      local timers, watches = {}, {}
      local new_timer, new_fs_event = vim.uv.new_timer, vim.uv.new_fs_event
      override(ReviewData, "start", start, function()
        override(vim.uv, "new_timer", function()
          local timer = new_timer()
          timers[#timers + 1] = timer
          return timer
        end, function()
          override(vim.uv, "new_fs_event", function()
            local handle = new_fs_event()
            watches[#watches + 1] = handle
            return handle
          end, function()
            for index = 1, 2 do
              local tab = Review.create(function()
                assert.is_true(timers[index]:is_closing())
                assert.is_true(watches[index]:is_closing())
                assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
                on_close()
              end)
              ---@cast tab any inspect feature-owned handles
              assert(
                vim.wait(5000, function()
                  return #watches == index
                end, 10),
                "Git observation did not start"
              )
              vim.api.nvim_win_close(tab.old_win, true)
              h.flush()
              assert.are.equal(index, closed)
            end
          end)
        end)
      end)
      assert.are.equal(2, #timers)
      assert.are.equal(2, #watches)
    end
  )

  for _, field in ipairs({ "winnr", "old_win", "new_win", "bufnr", "old_buf", "new_buf" }) do
    it("ends exactly once when owned " .. field .. " closes or wipes", function()
      local tab = Review.create(on_close)
      ---@cast tab any inspect feature-owned handles
      h.flush()
      assert.are.equal(1, reads)
      tab:jump(item)
      vim.api.nvim_set_current_win(source)
      if field:match("buf") then
        vim.api.nvim_buf_delete(tab[field], { force = true })
      else
        vim.api.nvim_win_close(tab[field], true)
      end
      assert.are.equal(1, closed)
      assert.are.equal(1, stopped)
      assert.are.same({}, groups())
      assert.is_nil(tab:current())
      for _, win in ipairs({ tab.old_win, tab.new_win }) do
        if vim.api.nvim_win_is_valid(win) then
          assert.is_false(vim.wo[win].diff)
          assert.is_false(vim.wo[win].winfixbuf)
        end
      end
      h.flush()
      assert.are.equal(1, closed)
      assert.are.same(tabs, vim.api.nvim_list_tabpages())
      assert.are.same(buffers, vim.api.nvim_list_bufs())
      assert.are.same({}, notes)
    end)
  end

  it("ends on forced body replacement and permits reopening before deferred cleanup", function()
    local first = Review.create(on_close)
    ---@cast first any inspect feature-owned handles
    h.flush()
    first:jump(item)
    vim.api.nvim_win_call(first.old_win, function()
      vim.cmd("enew!")
    end)
    assert.are.equal(1, closed)
    assert.is_false(vim.api.nvim_buf_is_valid(first.old_buf))
    local second = Review.create(on_close)
    h.flush()
    second:jump(item)
    assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal(1, #groups())
    assert.are.same({}, notes)
  end)

  it("reports synchronous read and render failures once and retains the previous Snapshot", function()
    local tab = Review.create(on_close)
    h.flush()
    assert.is_true(tab:current() == item)
    override(ReviewData, "read", function()
      error("read failed", 0)
    end, function()
      tab:refresh()
      h.flush()
      tab:refresh()
      h.flush()
    end)
    assert.are.equal(2, #notes)
    assert.is_true(tab:current() == item)
    local render = item.render
    override(item, "render", function()
      error("render failed", 0)
    end, function()
      tab:refresh()
      h.flush()
    end)
    assert.are.equal(3, #notes)
    assert.matches("render failed", notes[3])
    assert.are.equal(render, item.render)
    tab:refresh()
    h.flush()
    assert.is_true(tab:current() == item)
    assert.are.equal(3, #notes)
  end)

  it("keeps body work independent from refresh and suppresses its delivery after close", function()
    local tab = Review.create(on_close)
    h.flush()
    local jobs, stops, delivered = {}, {}, 0
    override(vim.fn, "jobstart", function(_, opts)
      jobs[#jobs + 1] = opts
      return 122 + #jobs
    end, function()
      override(vim.fn, "jobstop", function(jid)
        stops[#stops + 1] = jid
        return 1
      end, function()
        override(ReviewData, "text", function(ctx)
          Async({ "body" }):run(ctx):wait()
          delivered = delivered + 1
          return { old = "late old", new = "late new" }
        end, function()
          tab:jump(item)
          tab:refresh()
          h.flush()
          assert.are.same({}, stops)
          assert.are.equal(0, delivered)
          tab:jump(item)
          assert.are.same({ 123 }, stops)
          jobs[1].on_exit(123, 143)
          assert.are.equal(0, delivered)
          vim.cmd.close()
          assert.are.same({ 123, 124 }, stops)
          jobs[2].on_exit(124, 143)
          h.flush()
          assert.are.equal(0, delivered)
          assert.are.equal(1, closed)
          assert.are.same({}, notes)
        end)
      end)
    end)
  end)

  it("names captured revisions and paths and allows the preview sides to exchange names", function()
    local tab = Review.create(on_close)
    ---@cast tab any inspect owned version buffers
    h.flush()
    local selected = vim.tbl_extend("force", item, { base = string.rep("a", 40), target = "refs/heads/main" })
    tab:jump(selected)
    assert.are.equal("aaaaaaa://a.txt", vim.api.nvim_buf_get_name(tab.old_buf))
    assert.are.equal("refs/heads/main://a.txt", vim.fn.bufname(tab.new_buf))
    local swapped = vim.tbl_extend("force", selected, { base = selected.target, target = selected.base })
    tab:jump(swapped)
    assert.are.equal("refs/heads/main://a.txt", vim.fn.bufname(tab.old_buf))
    assert.are.equal("aaaaaaa://a.txt", vim.api.nvim_buf_get_name(tab.new_buf))
    swapped.old_path, swapped.path = "old\tname.txt", "new\nname.txt"
    tab:jump(swapped)
    assert.are.equal("refs/heads/main://old name.txt", vim.fn.bufname(tab.old_buf))
    assert.are.equal("aaaaaaa://new name.txt", vim.api.nvim_buf_get_name(tab.new_buf))
    assert.are.equal(string.rep("a", 40), selected.base)
    assert.are.same({}, notes)
  end)

  it("cancels both Git version processes when the UI closes", function()
    local tab = Review.create(on_close)
    h.flush()
    local jobs, stops = {}, {}
    local selected = vim.tbl_extend("force", item, { old_blob = "old-oid", new_blob = "new-oid" })
    override(vim.fn, "jobstart", function(_, opts)
      jobs[#jobs + 1] = opts
      return 122 + #jobs
    end, function()
      override(vim.fn, "jobstop", function(jid)
        stops[#stops + 1] = jid
        return 1
      end, function()
        override(ReviewData, "text", text, function()
          tab:jump(selected)
          assert.are.equal(2, #jobs)
          tab:refresh()
          h.flush()
          assert.are.same({}, stops)
          vim.cmd.close()
          table.sort(stops)
          assert.are.same({ 123, 124 }, stops)
          for index, opts in ipairs(jobs) do
            opts.on_stdout(122 + index, { "late" })
            opts.on_exit(122 + index, 143)
          end
          h.flush()
          assert.are.equal(1, closed)
          assert.are.same({}, notes)
        end)
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
    local ok, reason = pcall(Review.create, on_close)
    vim.o.winminwidth = minimum
    vim.o.winwidth = size
    assert.is_false(ok)
    assert.matches("E36", tostring(reason))
    assert.are.equal(0, closed)
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.same({}, groups())
  end)

  it("rolls back when native rows cannot fit the layout", function()
    local size, minimum = vim.o.winheight, vim.o.winminheight
    vim.o.winheight = vim.o.lines
    vim.o.winminheight = math.floor(vim.o.lines / 2) + 1
    local ok, reason = pcall(Review.create, on_close)
    vim.o.winminheight = minimum
    vim.o.winheight = size
    assert.is_false(ok)
    assert.matches("E36", tostring(reason))
    assert.are.equal(0, closed)
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.same({}, groups())
  end)
end)
