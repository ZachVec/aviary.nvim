---@module 'luassert'

local Async = require("aviary.shared.async")
local Git = require("aviary.hawk.review.git")

local function with_jobs(work)
  local jobstart, jobstop = vim.fn.jobstart, vim.fn.jobstop
  local jobs, stopped = {}, {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.jobstart = function(argv, opts)
    jobs[#jobs + 1] = { argv = argv, opts = opts }
    return #jobs
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.jobstop = function(jid)
    stopped[#stopped + 1] = jid
    return 1
  end
  local ok, reason = pcall(work, jobs, stopped)
  vim.fn.jobstart, vim.fn.jobstop = jobstart, jobstop
  assert(ok, reason)
end

describe("Review Git metadata queries", function()
  it("returns unique normalized metadata directories while retaining distinct worktree directories", function()
    for _, paths in ipairs({
      { "/repository/.git", "/repository/.git" },
      { "/repository/.git/", "/repository/.git" },
      { "/repository/.git/worktrees/topic", "/repository/.git" },
    }) do
      with_jobs(function(jobs)
        local result
        Async.run(function(ctx)
          result = Git.metadirs(ctx, "/repository")
        end, error)
        jobs[1].opts.on_stdout(1, { paths[1], paths[2], "" })
        jobs[1].opts.on_exit(1, 0)
        table.sort(result)
        local expected = { "/repository/.git" }
        if paths[1]:match("/worktrees/") then
          expected[2] = "/repository/.git/worktrees/topic"
        end
        assert.are.same(expected, result)
      end)
    end
  end)
end)

describe("Review Git version queries", function()
  it("starts both blob commands before waiting and returns structured results after out-of-order exits", function()
    with_jobs(function(jobs, stopped)
      local result
      Async.run(function(ctx)
        result = Git.versions(ctx, "/repository", "old-oid", "new-oid")
      end, error)
      assert.are.equal(2, #jobs)
      for _, job in ipairs(jobs) do
        assert.are.equal("/repository", job.opts.cwd)
        assert.are.equal("0", job.opts.env.GIT_OPTIONAL_LOCKS)
      end
      assert.are.equal("old-oid", jobs[1].argv[#jobs[1].argv])
      assert.are.equal("new-oid", jobs[2].argv[#jobs[2].argv])
      jobs[2].opts.on_stdout(2, { "new", "" })
      jobs[2].opts.on_exit(2, 0)
      assert.is_nil(result)
      jobs[1].opts.on_stdout(1, { "old", "" })
      jobs[1].opts.on_exit(1, 0)
      assert.are.same({ old = "old\n", new = "new\n" }, result)
      assert.are.same({}, stopped)
    end)
  end)

  it("returns empty content for absent objects without starting unused commands", function()
    with_jobs(function(jobs)
      local result
      Async.run(function(ctx)
        result = Git.versions(ctx, "/repository")
      end, error)
      assert.are.same({ old = "", new = "" }, result)
      assert.are.equal(0, #jobs)
      result = nil
      Async.run(function(ctx)
        result = Git.versions(ctx, "/repository", nil, "new-oid")
      end, error)
      assert.are.equal(1, #jobs)
      jobs[1].opts.on_stdout(1, { "new" })
      jobs[1].opts.on_exit(1, 0)
      assert.are.same({ old = "", new = "new" }, result)
    end)
  end)

  it("cancels both pending reads and suppresses their late results", function()
    with_jobs(function(jobs, stopped)
      local result, failures
      failures = 0
      local cancel = Async.run(function(ctx)
        result = Git.versions(ctx, "/repository", "old-oid", "new-oid")
      end, function()
        failures = failures + 1
      end)
      cancel()
      cancel()
      table.sort(stopped)
      assert.are.same({ 1, 2 }, stopped)
      for index, job in ipairs(jobs) do
        job.opts.on_stdout(index, { "late" })
        job.opts.on_exit(index, 143)
      end
      assert.is_nil(result)
      assert.are.equal(0, failures)
    end)
  end)

  it("reports a failed read once and stops the other pending blob process", function()
    with_jobs(function(jobs, stopped)
      local result, failures
      failures = {}
      local cancel = Async.run(function(ctx)
        result = Git.versions(ctx, "/repository", "old-oid", "new-oid")
      end, function(reason)
        failures[#failures + 1] = reason
      end)
      jobs[1].opts.on_stderr(1, { "missing blob" })
      jobs[1].opts.on_exit(1, 128)
      assert.are.same({ 2 }, stopped)
      assert.are.equal(1, #failures)
      assert.matches("missing blob", failures[1])
      jobs[2].opts.on_exit(2, 143)
      cancel()
      assert.is_nil(result)
      assert.are.equal(1, #failures)
    end)
  end)
end)
