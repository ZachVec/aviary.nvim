---@module 'luassert'

local Async = require("aviary.shared.async")

---@param ... string
---@return Cmd
local function command(...)
  return Async({ ... })
end

---@param work fun(ctx: AsyncContext): any
---@return any result
local function run_work(work)
  local finished, result, failure = false, nil, nil
  Async.run(function(ctx)
    result = work(ctx)
    finished = true
  end, function(reason)
    failure = reason
    finished = true
  end)
  assert(
    vim.wait(3000, function()
      return finished
    end),
    "work did not finish"
  )
  assert(failure == nil, failure)
  return result
end

--- Deterministic native events. No coroutine or handle internals are replaced.
---@param work fun(jobs: table[], stopped: integer[])
local function with_jobs(work)
  local saved_start, saved_stop = vim.fn.jobstart, vim.fn.jobstop
  local jobs, stopped = {}, {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.jobstart = function(argv, options)
    jobs[#jobs + 1] = { argv = argv, options = options }
    return #jobs
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.jobstop = function(jid)
    stopped[#stopped + 1] = jid
    return 1
  end
  local ok, reason = pcall(work, jobs, stopped)
  vim.fn.jobstart, vim.fn.jobstop = saved_start, saved_stop
  assert(ok, reason)
end

---@return string
local function temp_directory()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

describe("aviary.shared.async flows", function()
  it("starts synchronously and returns an idempotent cancellation function", function()
    local called, failures = false, 0
    local cancel = Async.run(function()
      called = true
      return 42
    end, function()
      failures = failures + 1
    end)
    assert.is_true(called)
    assert.is_function(cancel)
    cancel()
    cancel()
    assert.are.equal(0, failures)
  end)

  it("executes sequential commands and keeps independent flows isolated", function()
    with_jobs(function(jobs, stopped)
      local seen = {}
      local cancel = Async.run(function(ctx)
        seen[1] = command("first"):run(ctx):wait().stdout
        seen[2] = command("second"):run(ctx):wait().stdout
      end, error)
      Async.run(function(ctx)
        seen[3] = command("other"):run(ctx):wait().code
      end, error)
      assert.are.equal(2, #jobs)
      jobs[2].options.on_exit(2, 7)
      assert.are.equal(7, seen[3])
      assert.is_nil(seen[1])
      jobs[1].options.on_stdout(1, { "first", "" })
      jobs[1].options.on_exit(1, 0)
      assert.are.equal(3, #jobs)
      assert.are.equal("first\n", seen[1])
      jobs[3].options.on_stdout(3, { "second" })
      jobs[3].options.on_exit(3, 0)
      assert.are.equal("second", seen[2])
      cancel()
      assert.are.same({}, stopped)
    end)
  end)

  it("starts concurrent commands before waiting and resumes only the awaited handle", function()
    with_jobs(function(jobs, stopped)
      local result
      Async.run(function(ctx)
        local first = command("first"):run(ctx)
        local second = command("second"):run(ctx)
        assert.are.equal(2, #jobs)
        local left, right = first:wait(), second:wait()
        assert.is_true(left == first:wait())
        assert.is_true(right == second:wait())
        result = { left.stdout, right.stdout }
      end, error)
      jobs[2].options.on_stdout(2, { "second" })
      jobs[2].options.on_exit(2, 0)
      assert.is_nil(result)
      jobs[1].options.on_stdout(1, { "first" })
      jobs[1].options.on_exit(1, 0)
      assert.are.same({ "first", "second" }, result)
      assert.are.same({}, stopped)
    end)
  end)

  for _, completed in ipairs({ false, true }) do
    it("cancels concurrent work with the second command completed=" .. tostring(completed), function()
      with_jobs(function(jobs, stopped)
        local continued, failures = false, 0
        local cancel = Async.run(function(ctx)
          local first = command("first"):run(ctx)
          local second = command("second"):run(ctx)
          first:wait()
          second:wait()
          continued = true
        end, function()
          failures = failures + 1
        end)
        if completed then
          jobs[2].options.on_exit(2, 0)
        end
        cancel()
        cancel()
        table.sort(stopped)
        assert.are.same(completed and { 1 } or { 1, 2 }, stopped)
        jobs[1].options.on_exit(1, 143)
        if not completed then
          jobs[2].options.on_exit(2, 143)
        end
        assert.is_false(continued)
        assert.are.equal(0, failures)
      end)
    end)
  end

  it("stops unwaited commands when work returns or raises", function()
    for _, failed in ipairs({ false, true }) do
      with_jobs(function(jobs, stopped)
        local failures = {}
        local cancel = Async.run(function(ctx)
          command("first"):run(ctx)
          command("second"):run(ctx)
          if failed then
            error("work failed")
          end
        end, function(reason)
          assert.are.equal(2, #stopped)
          failures[#failures + 1] = reason
        end)
        table.sort(stopped)
        assert.are.same({ 1, 2 }, stopped)
        cancel()
        jobs[1].options.on_exit(1, 143)
        jobs[2].options.on_exit(2, 143)
        assert.are.equal(failed and 1 or 0, #failures)
        if failed then
          assert.matches("work failed", failures[1])
        end
      end)
    end
  end)

  it("cancels an unwaited sibling when wait rejects an exit code", function()
    with_jobs(function(jobs, stopped)
      local failures = {}
      local cancel = Async.run(function(ctx)
        local first = command("first"):run(ctx, { check = { 0 } })
        local second = command("second"):run(ctx, { check = { 0 } })
        first:wait()
        second:wait()
        error("must not continue")
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      jobs[1].options.on_stderr(1, { "rejected" })
      jobs[1].options.on_exit(1, 2)
      assert.are.same({ 2 }, stopped)
      assert.are.equal(1, #failures)
      assert.matches("rejected", failures[1])
      jobs[2].options.on_exit(2, 143)
      cancel()
      assert.are.equal(1, #failures)
    end)
  end)

  it("attempts every process cleanup and preserves work and cleanup failures", function()
    with_jobs(function(jobs, stopped)
      local jobstop, failures = vim.fn.jobstop, {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.jobstop = function(jid)
        jobstop(jid)
        if jid == 1 then
          error("stop failed")
        end
        return 1
      end
      local cancel = Async.run(function(ctx)
        command("first"):run(ctx)
        command("second"):run(ctx)
        error("work failed")
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      vim.fn.jobstop = jobstop
      cancel()
      table.sort(stopped)
      assert.are.same({ 1, 2 }, stopped)
      assert.are.equal(1, #failures)
      assert.matches("work failed", failures[1])
      assert.matches("stop failed", failures[1])
      jobs[1].options.on_exit(1, 143)
      jobs[2].options.on_exit(2, 143)
      assert.are.equal(1, #failures)
    end)
  end)

  it("stops an earlier process when a later command cannot start", function()
    with_jobs(function(jobs, stopped)
      local jobstart, failures = vim.fn.jobstart, {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.jobstart = function(...)
        if #jobs == 1 then
          error("second startup failed")
        end
        return jobstart(...)
      end
      local cancel = Async.run(function(ctx)
        command("first"):run(ctx)
        command("second"):run(ctx)
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      vim.fn.jobstart = jobstart
      assert.are.same({ 1 }, stopped)
      assert.are.equal(1, #failures)
      assert.matches("second startup failed", failures[1])
      jobs[1].options.on_exit(1, 143)
      cancel()
      assert.are.equal(1, #failures)
    end)
  end)

  it("cancels the current command without resuming work or reporting an error", function()
    with_jobs(function(jobs, stopped)
      local continued, failed = false, false
      local cancel = Async.run(function(ctx)
        command("first"):run(ctx):wait()
        command("must not start"):run(ctx):wait()
        continued = true
      end, function()
        failed = true
      end)
      cancel()
      cancel()
      assert.are.same({ 1 }, stopped)
      jobs[1].options.on_stdout(1, { "late output" })
      jobs[1].options.on_exit(1, 143)
      assert.are.equal(1, #jobs)
      assert.is_false(continued)
      assert.is_false(failed)
    end)
  end)

  it("cancels whichever command is currently running", function()
    with_jobs(function(jobs, stopped)
      local finished = false
      local cancel = Async.run(function(ctx)
        command("first"):run(ctx):wait()
        command("second"):run(ctx):wait()
        finished = true
      end, error)
      jobs[1].options.on_exit(1, 0)
      cancel()
      assert.are.same({ 2 }, stopped)
      jobs[2].options.on_exit(2, 143)
      assert.is_false(finished)
    end)
  end)

  it("releases cancelled coroutine locals while native callbacks and cancel stay live", function()
    with_jobs(function(jobs)
      local weak = setmetatable({}, { __mode = "v" })
      local cancel = Async.run(function(ctx)
        local payload = { "work state" }
        weak[1] = payload
        command("fake"):run(ctx):wait()
        assert.are.equal("work state", payload[1])
      end, error)
      collectgarbage("collect")
      assert.is_not_nil(weak[1])
      cancel()
      collectgarbage("collect")
      collectgarbage("collect")
      assert.is_nil(weak[1])
      jobs[1].options.on_exit(1, 143)
      cancel()
    end)
  end)

  it("releases completed coroutine locals while callbacks and cancel stay live", function()
    with_jobs(function(jobs, stopped)
      local weak = setmetatable({}, { __mode = "v" })
      local cancel = Async.run(function(ctx)
        local payload = { "work state" }
        weak[1] = payload
        command("fake"):run(ctx):wait()
        assert.are.equal("work state", payload[1])
      end, error)
      jobs[1].options.on_exit(1, 0)
      collectgarbage("collect")
      collectgarbage("collect")
      assert.is_nil(weak[1])
      cancel()
      assert.are.same({}, stopped)
    end)
  end)

  it("forwards cwd/env/stdin without modifying options", function()
    local root = temp_directory()
    vim.fn.writefile({ "marker" }, root .. "/marker")
    local opts = { cwd = root, env = { AVIARY_ASYNC_TEST = "yes" }, stdin = "input" }
    local before = vim.deepcopy(opts)
    local result = run_work(function(ctx)
      return command("sh", "-c", 'printf "%s|" "$AVIARY_ASYNC_TEST"; cat; test -f marker && printf "|found"')
        :run(ctx, opts)
        :wait()
    end)
    vim.fn.delete(root, "rf")
    assert.are.same(before, opts)
    assert.are.same({ code = 0, stdout = "yes|input|found", stderr = "" }, result)
  end)

  it("preserves empty stdin, raw NUL bytes and CRLF", function()
    for _, input in ipairs({ "", "one\ntwo", "a\r\nb\n" }) do
      local result = run_work(function(ctx)
        return command("cat"):run(ctx, { stdin = input }):wait()
      end)
      assert.are.equal(input, result.stdout)
    end
    local result = run_work(function(ctx)
      return command("sh", "-c", [[printf 'a\000b\r\nc'; printf 'err\r\n' >&2]]):run(ctx):wait()
    end)
    assert.are.equal("a\0b\r\nc", result.stdout)
    assert.are.equal("err\r\n", result.stderr)
  end)

  it("keeps argv and its metatable unchanged across reusable executions", function()
    local metadata = {}
    local argv = setmetatable({ "sh", "-c", "printf output" }, metadata)
    local cmd = Async(argv)
    local results = run_work(function(ctx)
      return { cmd:run(ctx):wait(), cmd:run(ctx):wait() }
    end)
    assert.are_not.equal(results[1], results[2])
    assert.are.equal("output", results[1].stdout)
    assert.are.same(results[1], results[2])
    assert.are.equal(metadata, getmetatable(argv))
    assert.are.same({ "sh", "-c", "printf output" }, argv)
  end)

  it("reports work errors before and after command completion with traceback", function()
    with_jobs(function(jobs, stopped)
      for _, pending in ipairs({ false, true }) do
        local calls, failure = 0, nil
        local cancel = Async.run(function(ctx)
          if pending then
            command("fake"):run(ctx):wait()
          end
          error("work failed")
        end, function(reason)
          calls, failure = calls + 1, reason
        end)
        if pending then
          assert.are.equal(0, calls)
          jobs[1].options.on_exit(1, 0)
        end
        assert.are.equal(1, calls)
        assert.is_truthy(tostring(failure):find("work failed", 1, true))
        assert.is_truthy(tostring(failure):find("stack traceback", 1, true))
        cancel()
      end
      assert.are.same({}, stopped)
    end)
  end)

  it("propagates error handler failures without invoking the handler twice", function()
    with_jobs(function(jobs)
      for _, pending in ipairs({ false, true }) do
        local calls = 0
        local function start()
          Async.run(function(ctx)
            if pending then
              command("fake"):run(ctx):wait()
            end
            error("work failed")
          end, function()
            calls = calls + 1
            error("handler failed")
          end)
        end
        local ok, reason
        if pending then
          start()
          ok, reason = pcall(jobs[#jobs].options.on_exit, #jobs, 0)
        else
          ok, reason = pcall(start)
        end
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("handler failed", 1, true))
        assert.are.equal(1, calls)
      end
    end)
  end)

  it("notifies failures by default before and after yielding, after stopping pending commands", function()
    for _, pending in ipairs({ false, true }) do
      with_jobs(function(jobs, stopped)
        local notify, failures = vim.notify, {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(reason, level, opts)
          table.sort(stopped)
          assert.are.same(pending and { 2 } or { 1, 2 }, stopped)
          assert.are.equal(vim.log.levels.ERROR, level)
          assert.are.same({ title = "aviary" }, opts)
          failures[#failures + 1] = reason
        end
        local ok, reason = pcall(function()
          local cancel = Async.run(function(ctx)
            local first = command("first"):run(ctx)
            command("second"):run(ctx)
            if pending then
              first:wait()
            end
            error("default failure")
          end)
          if pending then
            assert.are.equal(0, #failures)
            jobs[1].options.on_exit(1, 0)
          end
          assert.are.equal(1, #failures)
          assert.matches("default failure", failures[1])
          assert.matches("stack traceback", failures[1])
          cancel()
        end)
        vim.notify = notify
        assert(ok, reason)
      end)
    end
  end)

  it("reports startup failures and nonpositive job ids without leaving a flow active", function()
    local failure
    local cancel = Async.run(function(ctx)
      command("/definitely/missing/aviary-async-command"):run(ctx):wait()
    end, function(reason)
      failure = reason
    end)
    assert.is_truthy(tostring(failure):find("aviary-async-command", 1, true))
    cancel()
    local saved = vim.fn.jobstart
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function()
      return -1
    end
    Async.run(function(ctx)
      command("fake"):run(ctx):wait()
    end, function(reason)
      failure = reason
    end)
    vim.fn.jobstart = saved
    assert.is_truthy(tostring(failure):find("jobstart failed", 1, true))
  end)

  it("stops every acquired job when a later stdin setup fails", function()
    with_jobs(function(jobs, stopped)
      local saved = vim.fn.chansend
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.chansend = function()
        error("write failed")
      end
      local failure
      local cancel = Async.run(function(ctx)
        command("first"):run(ctx)
        command("fake"):run(ctx, { stdin = "input" }):wait()
      end, function(reason)
        failure = reason
      end)
      vim.fn.chansend = saved
      assert.is_truthy(tostring(failure):find("write failed", 1, true))
      table.sort(stopped)
      assert.are.same({ 1, 2 }, stopped)
      cancel()
      jobs[1].options.on_exit(1, 143)
      jobs[2].options.on_exit(2, 143)
      assert.are.same({ 1, 2 }, stopped)
    end)
  end)

  it("always collects both streams and preserves raw exit codes", function()
    for _, script in ipairs({ "exit 0", "exit 130", "kill -TERM $$" }) do
      local result = run_work(function(ctx)
        return command("sh", "-c", script):run(ctx):wait()
      end)
      assert.are.same(
        { code = script == "exit 0" and 0 or script == "exit 130" and 130 or 143, stdout = "", stderr = "" },
        result
      )
    end
  end)

  it("checks exit codes only when requested and stops subsequent work on failure", function()
    with_jobs(function(jobs)
      local failures, finished = {}, false
      local opts = { check = { 0 } }
      Async.run(function(ctx)
        command("fake"):run(ctx, opts):wait()
        command("must not start"):run(ctx, opts):wait()
        finished = true
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      jobs[1].options.on_stderr(1, { "  rejected  ", "" })
      jobs[1].options.on_exit(1, 9)
      assert.are.equal(1, #jobs)
      assert.is_false(finished)
      assert.are.equal(1, #failures)
      assert.is_truthy(failures[1]:find("rejected", 1, true))
      assert.is_truthy(failures[1]:find("stack traceback", 1, true))
      assert.are.same({ check = { 0 } }, opts)
      Async.run(function(ctx)
        command("empty stderr"):run(ctx, opts):wait()
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      jobs[2].options.on_stderr(2, { "  ", "" })
      jobs[2].options.on_exit(2, 4)
      assert.is_truthy(failures[2]:find("command exited with 4", 1, true))
    end)
    local success = run_work(function(ctx)
      return command("sh", "-c", "printf out; printf ' warning ' >&2"):run(ctx, { check = { 0 } }):wait()
    end)
    assert.are.same({ code = 0, stdout = "out", stderr = " warning " }, success)
    local unchecked = run_work(function(ctx)
      return command("sh", "-c", "printf err >&2; exit 9"):run(ctx):wait()
    end)
    assert.are.same({ code = 9, stdout = "", stderr = "err" }, unchecked)
  end)

  it("accepts exactly the listed exit codes without changing output or options", function()
    for _, case in ipairs({
      { codes = { 0, 1 }, code = 0, accepted = true },
      { codes = { 0, 1 }, code = 1, accepted = true },
      { codes = { 0, 1 }, code = 2, accepted = false },
      { codes = { 1 }, code = 0, accepted = false },
      { codes = {}, code = 0, accepted = false },
    }) do
      with_jobs(function(jobs)
        local opts = { check = case.codes }
        local before = vim.deepcopy(opts)
        local result, failure
        Async.run(function(ctx)
          result = command("fake"):run(ctx, opts):wait()
          command("next"):run(ctx):wait()
        end, function(reason)
          failure = reason
        end)
        jobs[1].options.on_stdout(1, { "out", "" })
        jobs[1].options.on_stderr(1, { " warning " })
        jobs[1].options.on_exit(1, case.code)
        assert.are.same(before, opts)
        if case.accepted then
          assert.is_nil(failure)
          assert.are.same({ code = case.code, stdout = "out\n", stderr = " warning " }, result)
          assert.are.equal(2, #jobs)
          jobs[2].options.on_exit(2, 0)
        else
          assert.is_nil(result)
          assert.is_truthy(tostring(failure):find("warning", 1, true))
          assert.are.equal(1, #jobs)
        end
      end)
    end
  end)

  it("stops real process groups and abandons the remaining work", function()
    if vim.fn.has("unix") ~= 1 then
      return
    end
    local root = temp_directory()
    local ready, marker = root .. "/ready", root .. "/leaked"
    local finished, failed = false, false
    local cancel = Async.run(function(ctx)
      command("sh", "-c", '(sleep 0.3; printf leaked > "$2") & printf ready > "$1"; wait', "sh", ready, marker)
        :run(ctx)
        :wait()
      finished = true
    end, function()
      failed = true
    end)
    local started = vim.wait(2000, function()
      return vim.fn.filereadable(ready) == 1
    end)
    cancel()
    cancel()
    vim.wait(400)
    local leaked = vim.fn.filereadable(marker)
    vim.fn.delete(root, "rf")
    assert.is_true(started)
    assert.are.equal(0, leaked)
    assert.is_false(finished)
    assert.is_false(failed)
  end)
end)
