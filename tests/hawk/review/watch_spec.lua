---@module 'luassert'

local Review = require("aviary.hawk.review.review")
local h = require("hawk.helpers")

describe("Git metadata observation", function()
  local dir, stop, cwd, group
  local function observe(callback)
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AviaryReviewChanged",
      callback = callback,
    })
  end
  before_each(function()
    cwd, stop = vim.fn.getcwd(-1, -1), nil
    group = vim.api.nvim_create_augroup("aviary.hawk.review.watch.test", { clear = true })
    dir = h.repo()
    h.write(dir, "file", { "old" })
    h.commit(dir)
    vim.cmd.cd(dir)
  end)
  after_each(function()
    if stop then
      stop()
      stop()
    end
    vim.api.nvim_del_augroup_by_id(group)
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, "rf")
  end)
  local function wait_for(predicate)
    assert(vim.wait(5000, predicate, 10), "watch event timed out")
  end

  it("emits debounced changes for atomic index replacement and packed refs until stopped", function()
    local events = 0
    observe(function()
      events = events + 1
    end)
    stop = Review.start()
    wait_for(function()
      return events > 0
    end)
    local previous = events
    h.write(dir, "file", { "staged" })
    h.git(dir, { "add", "file" })
    wait_for(function()
      return events > previous
    end)
    previous = events
    h.git(dir, { "branch", "nested/deep/branch" })
    h.git(dir, { "pack-refs", "--all" })
    wait_for(function()
      return events > previous
    end)
    stop()
    previous = events
    h.git(dir, { "reset", "-q", "HEAD" })
    local waited = false
    vim.defer_fn(function()
      waited = true
    end, 200)
    wait_for(function()
      return waited
    end)
    assert.are.equal(previous, events)
  end)

  it("reports timer acquisition failure after discovery while retaining directory observation until stopped", function()
    local jobstart, new_timer, notify = vim.fn.jobstart, vim.uv.new_timer, vim.notify
    local options, notes = {}, {}
    local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      error("timer acquisition failed", 0)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    local ok, reason = pcall(function()
      observe(function()
        error("failed watch emitted an event")
      end)
      stop = Review.start()
      options.on_stdout(123, { dir .. "/.git", dir .. "/.git", "" })
      options.on_exit(123, 0)
      assert.are.equal(1, #notes)
      assert.matches("timer acquisition failed", notes[1])
      assert.are.equal(#observers + 1, #vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      stop()
      assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
    end)
    vim.fn.jobstart, vim.uv.new_timer, vim.notify = jobstart, new_timer, notify
    assert(ok, reason)
  end)

  it(
    "reports discovery startup failure without acquiring debounce and retains directory observation until stopped",
    function()
      local new_timer, jobstart, notify = vim.uv.new_timer, vim.fn.jobstart, vim.notify
      local notes, timers = {}, 0
      local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.uv.new_timer = function()
        timers = timers + 1
        return new_timer()
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.jobstart = function()
        error("discovery process could not start", 0)
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(message)
        notes[#notes + 1] = message
      end
      local ok, reason = pcall(function()
        observe(function()
          error("failed discovery emitted an event")
        end)
        stop = Review.start()
        assert.are.equal(0, timers)
        assert.are.equal(1, #notes)
        assert.matches("discovery process could not start", notes[1])
        assert.are.equal(#observers + 1, #vim.api.nvim_get_autocmds({ event = "DirChanged" }))
        stop()
        assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      end)
      vim.uv.new_timer, vim.fn.jobstart, vim.notify = new_timer, jobstart, notify
      assert(ok, reason)
    end
  )

  it("cancels pending discovery without installing watchers or reporting failure", function()
    local jobstart, jobstop, new_fs_event, notify = vim.fn.jobstart, vim.fn.jobstop, vim.uv.new_fs_event, vim.notify
    ---@type table
    local options = {}
    local stopped, watchers, notes = {}, 0, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstop = function(jid)
      stopped[#stopped + 1] = jid
      return 1
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      watchers = watchers + 1
      return new_fs_event()
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
      end)
      stop = Review.start()
      stop()
      stop()
      options.on_stdout(123, { dir .. "/.git", dir .. "/.git", "" })
      options.on_exit(123, 143)
      h.flush()
      assert.are.same({ 123 }, stopped)
      assert.are.equal(0, watchers)
      assert.are.equal(0, events)
      assert.are.same({}, notes)
    end)
    vim.fn.jobstart, vim.fn.jobstop, vim.uv.new_fs_event, vim.notify = jobstart, jobstop, new_fs_event, notify
    assert(ok, reason)
  end)

  it("closes acquired watches when a directory watch cannot start", function()
    local jobstart, new_timer, new_fs_event, notify = vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event, vim.notify
    local options, notes, created, timers = {}, {}, {}, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      local timer = assert(new_timer())
      timers[#timers + 1] = timer
      return timer
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      local index = #created + 1
      ---@type any
      local handle = { closed = false }
      function handle:start(_, _, callback)
        self.event = callback
        if index == 2 then
          return nil, "watch unavailable"
        end
        return 0
      end
      function handle:close()
        self.closed = true
      end
      created[#created + 1] = handle
      return handle
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
      end)
      stop = Review.start()
      options.on_stdout(123, { dir .. "/.git", dir .. "/common", "" })
      options.on_exit(123, 0)
      assert.are.equal(0, events)
      assert.are.equal(1, #notes)
      assert.matches("watch unavailable", notes[1])
      assert.is_true(timers[1]:is_closing())
      assert.are.equal(2, #created)
      for _, handle in ipairs(created) do
        assert.is_true(handle.closed)
        handle.event(nil, "index")
        handle.event("late watch error")
      end
      h.flush()
      assert.are.equal(0, events)
      assert.are.equal(1, #notes)
      stop()
    end)
    vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event, vim.notify = jobstart, new_timer, new_fs_event, notify
    assert(ok, reason)
  end)

  it("closes watches before raising a filesystem error on the main loop and suppresses later errors", function()
    local jobstart, new_timer, new_fs_event, schedule =
      vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event, vim.schedule
    local options, timers, handles, callbacks, pending = {}, {}, {}, {}, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      local timer = assert(new_timer())
      timers[#timers + 1] = timer
      return timer
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      ---@type any
      local handle = { closed = false }
      function handle:start(_, _, callback)
        callbacks[#callbacks + 1] = callback
        return 0
      end
      function handle:close()
        self.closed = true
      end
      handles[#handles + 1] = handle
      return handle
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
      end)
      stop = Review.start()
      options.on_stdout(123, { dir .. "/.git", dir .. "/.git", "" })
      options.on_exit(123, 0)
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.schedule = function(callback)
        pending[#pending + 1] = callback
      end
      callbacks[1]("watch failed")
      callbacks[1]("later failure")
      assert.are.equal(2, #pending)
      assert.is_false(timers[1]:is_closing())
      local delivered, cause = pcall(pending[1])
      assert.is_false(delivered)
      assert.are.equal("watch failed", cause)
      assert.is_true(timers[1]:is_closing())
      assert.is_true(handles[1].closed)
      pending[2]()
      callbacks[1]("late failure")
      assert.are.equal(2, #pending)
      assert.are.equal(1, events)
      stop()
    end)
    vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event, vim.schedule = jobstart, new_timer, new_fs_event, schedule
    assert(ok, reason)
  end)

  it("watches only deduplicated roots, filters locks and suppresses queued refresh after close", function()
    local jobstart, new_timer, new_fs_event = vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event
    local options, watches, callbacks = {}, {}, {}
    ---@type any
    local timer = {}
    function timer:start(_, _, callback)
      callbacks[#callbacks + 1] = callback
    end
    function timer:stop() end
    function timer:close() end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      return timer
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      ---@type any
      local handle = {}
      function handle:start(path, _, callback)
        watches[path] = callback
        return 0
      end
      function handle:close() end
      return handle
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
      end)
      stop = Review.start()
      options.on_stdout(123, { dir .. "/.git", dir .. "/.git", "" })
      options.on_exit(123, 0)
      assert.are.equal(1, events)
      local root_event = assert(watches[dir .. "/.git"])
      assert.are.same({ dir .. "/.git" }, vim.tbl_keys(watches))
      root_event(nil, "index.lock")
      assert.are.equal(0, #callbacks)
      root_event(nil, "description")
      root_event(nil, "index")
      root_event(nil, "HEAD")
      assert.are.equal(3, #callbacks)
      assert.are.equal(1, events)
      callbacks[3]() -- queue refresh on the main loop
      h.flush()
      assert.are.equal(2, events)
      root_event(nil, "index")
      callbacks[4]()
      stop()
      root_event(nil, "index")
      h.flush()
      assert.are.equal(2, events)
      assert.are.equal(4, #callbacks)
    end)
    vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event = jobstart, new_timer, new_fs_event
    assert(ok, reason)
  end)

  it("rebinds global cwd and suppresses old discovery, events and queued debounce", function()
    local other = h.repo()
    local jobstart, jobstop = vim.fn.jobstart, vim.fn.jobstop
    local new_timer, new_fs_event = vim.uv.new_timer, vim.uv.new_fs_event
    local jobs, stopped, timers, watches = {}, {}, {}, {}
    local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      jobs[#jobs + 1] = { root = opts.cwd, opts = opts }
      return 122 + #jobs
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstop = function(jid)
      stopped[#stopped + 1] = jid
      return 1
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      ---@type any
      local timer = { closed = false }
      function timer:start(_, _, callback)
        self.fire = callback
      end
      function timer:stop() end
      function timer:close()
        self.closed = true
      end
      timers[#timers + 1] = timer
      return timer
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      ---@type any
      local handle = { closed = false }
      function handle:start(path, _, callback)
        self.path, self.event = path, callback
        return 0
      end
      function handle:close()
        self.closed = true
      end
      watches[#watches + 1] = handle
      return handle
    end
    local function finish(index)
      local job = jobs[index]
      job.opts.on_stdout(122 + index, { job.root .. "/.git", "" })
      job.opts.on_exit(122 + index, 0)
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
      end)
      stop = Review.start()
      assert.are.equal(dir, jobs[1].root)
      vim.cmd.lcd(other .. "/.git")
      assert.are.equal(1, #jobs)
      vim.cmd.cd(other)
      assert.are.same({ 123 }, stopped)
      assert.are.equal(0, #timers)
      assert.are.equal(other, jobs[2].root)
      assert.are.equal(1, events)
      finish(1)
      assert.are.equal(0, #watches)
      assert.are.equal(1, events)
      finish(2)
      assert.are.equal(other .. "/.git", watches[1].path)
      assert.are.equal(2, events)
      watches[1].event(nil, "index")
      timers[1].fire()
      vim.cmd.cd(dir)
      assert.is_true(watches[1].closed)
      assert.is_true(timers[1].closed)
      assert.are.equal(dir, jobs[3].root)
      watches[1].event(nil, "index")
      h.flush()
      assert.are.equal(3, events)
      finish(3)
      assert.are.equal(4, events)
      stop()
      stop()
      assert.is_true(watches[2].closed)
      assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      vim.cmd.cd(other)
      assert.are.equal(3, #jobs)
      assert.are.equal(4, events)
    end)
    if stop then
      stop()
    end
    vim.cmd.cd(dir)
    vim.fn.jobstart, vim.fn.jobstop = jobstart, jobstop
    vim.uv.new_timer, vim.uv.new_fs_event = new_timer, new_fs_event
    vim.fn.delete(other, "rf")
    assert(ok, reason)
  end)

  it("can stop inside a directory change event without retaining the new binding", function()
    local other = h.repo()
    local jobstart, jobstop = vim.fn.jobstart, vim.fn.jobstop
    local jobs, stopped = {}, {}
    local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      jobs[#jobs + 1] = opts
      return 122 + #jobs
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstop = function(jid)
      stopped[#stopped + 1] = jid
      return 1
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
        stop()
      end)
      stop = Review.start()
      vim.cmd.cd(other)
      assert.are.same({ 123, 124 }, stopped)
      assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      for index, opts in ipairs(jobs) do
        opts.on_exit(122 + index, 143)
      end
      assert.are.equal(1, events)
      stop()
      assert.are.same({ 123, 124 }, stopped)
    end)
    if stop then
      stop()
    end
    vim.cmd.cd(dir)
    vim.fn.jobstart, vim.fn.jobstop = jobstart, jobstop
    vim.fn.delete(other, "rf")
    assert(ok, reason)
  end)

  it("can stop from discovery completion while releasing the newly constructed Watch", function()
    local jobstart, new_timer, new_fs_event = vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event
    local options, timers, watches = {}, {}, {}
    local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(_, opts)
      options = opts
      return 123
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      local timer = assert(new_timer())
      timers[#timers + 1] = timer
      return timer
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_fs_event = function()
      local handle = assert(new_fs_event())
      watches[#watches + 1] = handle
      return handle
    end
    local ok, reason = pcall(function()
      local events = 0
      observe(function()
        events = events + 1
        stop()
      end)
      stop = Review.start()
      options.on_stdout(123, { dir .. "/.git", dir .. "/.git", "" })
      options.on_exit(123, 0)
      assert.are.equal(1, events)
      assert.are.equal(1, #timers)
      assert.are.equal(1, #watches)
      assert.is_true(timers[1]:is_closing())
      assert.is_true(watches[1]:is_closing())
      assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      stop()
    end)
    vim.fn.jobstart, vim.uv.new_timer, vim.uv.new_fs_event = jobstart, new_timer, new_fs_event
    assert(ok, reason)
  end)

  it("starts outside Git with only a directory observer and releases it on stop", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.cmd.cd(outside)
    local observers = vim.api.nvim_get_autocmds({ event = "DirChanged" })
    local new_timer, jobstart = vim.uv.new_timer, vim.fn.jobstart
    local timers, jobs = 0, 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.new_timer = function()
      timers = timers + 1
      return new_timer()
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(...)
      jobs = jobs + 1
      return jobstart(...)
    end
    local ok, reason = pcall(function()
      stop = Review.start()
      assert.are.equal(#observers + 1, #vim.api.nvim_get_autocmds({ event = "DirChanged" }))
      assert.are.equal(0, timers)
      assert.are.equal(0, jobs)
      stop()
      stop()
      assert.are.same(observers, vim.api.nvim_get_autocmds({ event = "DirChanged" }))
    end)
    vim.uv.new_timer, vim.fn.jobstart = new_timer, jobstart
    if stop then
      stop()
    end
    vim.cmd.cd(dir)
    vim.fn.delete(outside, "rf")
    assert(ok, reason)
  end)

  it("emits a change and pauses outside Git, then resumes observation on return", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local events = 0
    observe(function()
      events = events + 1
    end)
    local ok, reason = pcall(function()
      stop = Review.start()
      wait_for(function()
        return events > 0
      end)
      local previous = events
      vim.cmd.cd(outside)
      h.flush()
      assert.are.equal(previous + 1, events)
      vim.cmd.cd(dir)
      wait_for(function()
        return events >= previous + 3
      end)
      stop()
      previous = events
      vim.cmd.cd(outside)
      h.flush()
      assert.are.equal(previous, events)
    end)
    if stop then
      stop()
    end
    vim.cmd.cd(dir)
    vim.fn.delete(outside, "rf")
    assert(ok, reason)
  end)

  it("watches a linked worktree index and its common Git directory", function()
    local worktree = dir .. "-linked"
    h.git(dir, { "worktree", "add", "-qb", "linked", worktree })
    local events = 0
    vim.cmd.cd(worktree)
    observe(function()
      events = events + 1
    end)
    stop = Review.start()
    wait_for(function()
      return events > 0
    end)
    local previous = events
    h.write(worktree, "file", { "linked stage" })
    h.git(worktree, { "add", "file" })
    wait_for(function()
      return events > previous
    end)
    previous = events
    h.git(dir, { "branch", "shared-ref" })
    h.git(dir, { "pack-refs", "--all" })
    wait_for(function()
      return events > previous
    end)
    stop()
    vim.cmd.cd(dir)
    h.git(dir, { "worktree", "remove", "--force", worktree })
  end)
end)
