---@module 'luassert'

local Async = require("aviary.shared.async")
local Review = require("aviary.hawk.review.review")
local h = require("hawk.helpers")

local function await(work)
  local finished, values, reason = false, {}, nil
  Async.run(function(ctx)
    values = { work(ctx) }
    finished = true
  end, function(err)
    reason, finished = err, true
  end)
  assert(
    vim.wait(5000, function()
      return finished
    end, 10),
    "Git read timed out"
  )
  if reason then
    return nil, reason
  end
  return unpack(values)
end

local function paths(items)
  return vim.tbl_map(function(item)
    return item.path
  end, items)
end

describe("review Git object comparisons", function()
  local dir
  before_each(function()
    dir = h.repo()
    h.write(dir, "a.txt", { "before" })
    h.write(dir, "b.txt", { "other" })
    h.commit(dir)
  end)
  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local function read(base, target, style)
    return await(function(ctx)
      return Review.read(ctx, {
        root = dir,
        base = base or "HEAD",
        target = target or "index",
        style = style or "direct",
      })
    end)
  end
  local function text(item)
    return assert(await(function(ctx)
      return Review.text(ctx, item)
    end))
  end

  it("returns an empty comparison without running Git when no repository was captured", function()
    local jobstart, jobs = vim.fn.jobstart, 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(...)
      jobs = jobs + 1
      return jobstart(...)
    end
    local ok, reason = pcall(function()
      for _, selection in ipairs({
        { target = "index", style = "direct" },
        { base = "missing-ref", target = "missing-target", style = "merge_base" },
      }) do
        local original = vim.deepcopy(selection)
        local items, base = await(function(ctx)
          return Review.read(ctx, selection)
        end)
        assert.are.same({}, items)
        assert.is_nil(base)
        assert.are.same(original, selection)
      end
    end)
    vim.fn.jobstart = jobstart
    assert(ok, reason)
    assert.are.equal(0, jobs)
  end)

  it("follows HEAD for an omitted base while explicit commits stay fixed, including detached HEAD", function()
    local head = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
    for _, detached in ipairs({ false, true }) do
      if detached then
        h.git(dir, { "checkout", "--detach", "HEAD" })
      end
      h.write(dir, "a.txt", { "staged" })
      h.git(dir, { "add", "a.txt" })
      local selection = { root = dir, target = "index", style = "direct" }
      local items, base = await(function(ctx)
        return Review.read(ctx, selection)
      end)
      assert.are.equal("HEAD", base)
      assert.are.same({ "a.txt" }, paths(items))
      local captured = assert(items)[1]
      assert.are.equal("HEAD", captured.base)
      assert.are.equal("index", captured.target)
      assert.is_nil(selection.base)
      h.commit(dir)
      assert.are.same(
        {},
        assert(await(function(ctx)
          return Review.read(ctx, selection)
        end))
      )
      assert.is_nil(selection.base)
      assert.are.same({ old = "before\n", new = "staged\n" }, text(captured))
      assert.are.same(
        { "a.txt" },
        paths(assert(await(function(ctx)
          return Review.read(ctx, { root = dir, base = head, target = "index", style = "direct" })
        end)))
      )
      h.git(dir, { "reset", "--hard", head })
    end
  end)

  it("reports an error when the default HEAD has no commit", function()
    h.git(dir, { "checkout", "--orphan", "unborn" })
    local items, reason = await(function(ctx)
      return Review.read(ctx, { root = dir, target = "index", style = "direct" })
    end)
    assert.is_nil(items)
    assert.is_truthy(tostring(reason):find("HEAD", 1, true))
  end)

  it("shows only staged objects, sorted by exact path, and freezes blob versions", function()
    h.write(dir, "a.txt", { "staged" })
    h.write(dir, "z\tline\n.txt", { "new" })
    h.git(dir, { "add", "-A" })
    h.write(dir, "a.txt", { "unstaged" })
    h.write(dir, "untracked", { "exclude" })
    local items = assert(read())
    assert.are.same({ "a.txt", "z\tline\n.txt" }, paths(items))
    local modified, added = items[1]:render(80), items[2]:render(80)
    assert.are.equal("M a.txt +1 -1", modified.text)
    assert.are.same({
      { start_col = 0, end_col = 1, hl = "Changed" },
      { start_col = 2, end_col = 7, hl = "Directory" },
      { start_col = 8, end_col = 10, hl = "Added" },
      { start_col = 11, end_col = 13, hl = "Removed" },
    }, modified.highlights)
    assert.are.equal("A z line .txt +1 -0", added.text)
    assert.are.equal("Added", added.highlights[1].hl)
    h.git(dir, { "add", "a.txt" })
    assert.are.same({ old = "before\n", new = "staged\n" }, text(items[1]))
    assert.are.same({ old = "", new = "new\n" }, text(items[2]))
  end)

  it("compares arbitrary commits and merge-base style independently", function()
    local initial = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
    h.git(dir, { "checkout", "-qb", "side" })
    h.write(dir, "side.txt", { "side" })
    h.commit(dir)
    h.git(dir, { "checkout", "-q", "main" })
    h.write(dir, "main.txt", { "main" })
    h.commit(dir)
    local direct = assert(read("side", "main"))
    assert.are.same({ "main.txt", "side.txt" }, paths(direct))
    assert.are.equal("side", direct[1].base)
    assert.are.equal("main", direct[1].target)
    local pr = assert(read("side", "main", "merge_base"))
    assert.are.same({ "main.txt" }, paths(pr))
    assert.are.equal(initial, pr[1].base)
    assert.are.equal("main", pr[1].target)
    local fixed = assert(read(initial, "main"))
    assert.are.same({ "main.txt" }, paths(fixed))
    h.write(dir, "staged.txt", { "staged" })
    h.git(dir, { "add", "-A" })
    assert.are.same({ "main.txt", "staged.txt" }, paths(assert(read("side", "index", "merge_base"))))
  end)

  it("omits whole directories in ordinary rows without changing their paths or byte highlights", function()
    local path = "path/to/long_name_directory/file.lua"
    h.write(dir, path, { "new" })
    h.git(dir, { "add", "-A" })
    local entry = assert(read())[1]
    local rendered = entry:render(26)
    assert.are.equal("A path/to/…/file.lua +1 -0", rendered.text)
    local span = rendered.highlights[2]
    assert.are.equal("path/to/…/file.lua", rendered.text:sub(span.start_col + 1, span.end_col))
    assert.are.equal("A file.lua +1 -0", entry:render(16).text)
    assert.are.equal(path, entry.path)
  end)

  it("places unpadded changes after a middle-shortened rename pair without changing metadata", function()
    vim.fn.mkdir(dir .. "/long-directory", "p")
    h.git(dir, { "mv", "a.txt", "long-directory/中文文件.txt" })
    local entries = assert(read())
    local entry = entries[1]
    local full = entry:render(80)
    assert.are.equal("R a.txt → long-directory/中文文件.txt +0 -0", full.text)
    assert.are.equal("R a.txt → lo…文文件.txt +0 -0", entry:render(30).text)
    assert.are.equal("R … +0 -0", entry:render(0).text)
    assert.are.same(
      {
        { "R", "Changed" },
        { "a.txt → long-directory/中文文件.txt", "Directory" },
        { "+0", "Added" },
        { "-0", "Removed" },
      },
      vim.tbl_map(function(span)
        return { full.text:sub(span.start_col + 1, span.end_col), span.hl }
      end, full.highlights)
    )
    assert.are.equal("long-directory/中文文件.txt", entry.path)
    assert.are.equal("a.txt", entry.old_path)
  end)

  it("caps displayed counts at 10k+ while retaining exact values without padding", function()
    h.write(dir, "a.txt", vim.split(string.rep("new\n", 9999), "\n", { trimempty = true }))
    h.git(dir, { "add", "-A" })
    assert.are.equal("M a.txt +9999 -1", assert(read())[1]:render(80).text)
    h.write(dir, "a.txt", vim.split(string.rep("new\n", 10000), "\n", { trimempty = true }))
    h.git(dir, { "add", "-A" })
    local entry = assert(read())[1]
    local rendered = entry:render(80)
    assert.are.equal("M a.txt +10k+ -1", rendered.text)
    assert.are.equal(10000, entry.added)
    assert.are.equal(1, entry.removed)
    local added = rendered.highlights[3]
    assert.are.equal("+10k+", rendered.text:sub(added.start_col + 1, added.end_col))
  end)

  it("handles rename, deletion, empty, binary and mode-only files", function()
    h.git(dir, { "mv", "a.txt", "renamed.txt" })
    h.git(dir, { "rm", "b.txt" })
    h.write(dir, "empty.txt", {})
    local fd = assert(vim.uv.fs_open(dir .. "/binary.dat", "w", 420))
    assert(vim.uv.fs_write(fd, "x\000y", 0))
    vim.uv.fs_close(fd)
    h.git(dir, { "add", "-A" })
    local items = assert(read())
    assert.are.same({ "b.txt", "binary.dat", "empty.txt", "renamed.txt" }, paths(items))
    assert.are.equal("D", items[1].status)
    assert.are.equal("D b.txt +0 -1", items[1]:render(80).text)
    assert.are.equal("Removed", items[1]:render(80).highlights[1].hl)
    assert.is_nil(items[1].new_blob)
    assert.are.equal("binary", items[2].kind)
    assert.is_nil(items[2].added)
    assert.are.equal("A binary.dat — —", items[2]:render(80).text)
    assert.are.equal(0, items[3].added)
    assert.are.equal("a.txt", items[4].old_path)
    assert.are.equal("R", items[4].status)
    assert.are.same({ old = "other\n", new = "" }, text(items[1]))
    assert.is_truthy(text(items[2]).new:find("[binary]", 1, true))
    assert.are.same({ old = "before\n", new = "before\n" }, text(items[4]))
    h.commit(dir)
    h.git(dir, { "update-index", "--chmod=+x", "renamed.txt" })
    assert.are.equal("M renamed.txt +0 -0", assert(read())[1]:render(80).text)
  end)

  it("keeps conflicts and submodules explicit rather than reading commit objects as text", function()
    h.git(dir, { "checkout", "-qb", "side" })
    h.write(dir, "a.txt", { "side" })
    h.commit(dir)
    h.git(dir, { "checkout", "-q", "main" })
    h.write(dir, "a.txt", { "main" })
    h.commit(dir)
    assert.are.equal(1, vim.system({ "git", "merge", "side" }, { cwd = dir }):wait().code)
    h.write(dir, "b.txt", { "staged other" })
    h.git(dir, { "add", "b.txt" })
    local items = assert(read())
    assert.are.same({ "a.txt", "b.txt" }, paths(items))
    assert.are.equal("unmerged", items[1].kind)
    assert.are.equal("DiagnosticWarn", items[1]:render(80).highlights[1].hl)
    assert.is_truthy(text(items[1]).new:find("[unmerged]", 1, true))
    h.git(dir, { "merge", "--abort" })
    local sha = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
    h.git(dir, { "update-index", "--add", "--cacheinfo", "160000," .. sha .. ",module" })
    local sub = assert(read())[1]
    assert.are.equal("submodule", sub.kind)
    assert.is_truthy(text(sub).new:find(sha, 1, true))
  end)

  it("leaves error handling and cancellation with the calling flow", function()
    local items, reason = read("missing-ref")
    assert.is_nil(items)
    assert.is_string(reason)
    local called = false
    local cancel = Async.run(function(ctx)
      Review.read(ctx, { root = dir, base = "HEAD", target = "index", style = "direct" })
      called = true
    end)
    cancel()
    cancel()
    h.flush()
    assert.is_false(called)
    local reports = {}
    cancel = Async.run(function(ctx)
      local result = Review.text(ctx, {
        base = "HEAD",
        target = "index",
        root = dir,
        path = "x",
        kind = "binary",
        status = "M",
        render = function()
          return { text = "x", highlights = {} }
        end,
      })
      assert.are.same({ old = "[binary] absent\n", new = "[binary] absent\n" }, result)
      error("consumer failed", 0)
    end, function(err)
      reports[#reports + 1] = err
    end)
    cancel()
    cancel()
    assert.are.equal(1, #reports)
    assert.matches("consumer failed", reports[1])
  end)

  it("cancels merge-base work before diff can start", function()
    local saved_start, saved_stop = vim.fn.jobstart, vim.fn.jobstop
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
    local ok, reason = pcall(function()
      local called = false
      local cancel = Async.run(function(ctx)
        Review.read(ctx, { root = dir, base = "main", target = "index", style = "merge_base" })
        called = true
      end)
      assert.are.equal(1, #jobs)
      assert.is_true(vim.tbl_contains(jobs[1].argv, "merge-base"))
      cancel()
      cancel()
      jobs[1].opts.on_stdout(1, { string.rep("a", 40), "" })
      jobs[1].opts.on_exit(1, 143)
      h.flush()
      assert.are.equal(1, #jobs)
      assert.are.same({ 1 }, stopped)
      assert.is_false(called)
    end)
    vim.fn.jobstart, vim.fn.jobstop = saved_start, saved_stop
    assert(ok, reason)
  end)

  it("compares fetched remote branches and annotated tags without checking them out", function()
    local remote = dir .. "-remote"
    local ok, reason = pcall(function()
      h.git(dir, { "clone", "-q", dir, remote })
      h.git(remote, { "config", "user.email", "test@example.com" })
      h.git(remote, { "config", "user.name", "test" })
      h.git(remote, { "checkout", "-qb", "topic" })
      h.write(remote, "a.txt", { "remote change" })
      h.commit(remote)
      h.git(remote, { "tag", "-a", "remote-tag", "-m", "review" })
      h.git(dir, { "remote", "add", "origin", remote })
      h.git(dir, { "fetch", "-q", "origin", "--tags" })
      h.git(dir, { "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" })
      local choices = assert(await(function(ctx)
        return Review.choices(ctx, dir, "ref", false)
      end))
      local by_ref = {}
      for _, choice in ipairs(choices) do
        by_ref[choice.revision] = choice
      end
      assert.is_not_nil(by_ref["refs/heads/main"])
      assert.is_not_nil(by_ref["refs/remotes/origin/topic"])
      assert.is_not_nil(by_ref["refs/tags/remote-tag"])
      assert.is_nil(by_ref["HEAD"])
      assert.is_nil(by_ref["refs/remotes/origin/HEAD"])
      for _, ref in ipairs({ "refs/remotes/origin/topic", "refs/tags/remote-tag" }) do
        local items = assert(read("refs/heads/main", by_ref[ref].revision))
        assert.are.same({ "a.txt" }, paths(items))
        assert.are.same({ old = "before\n", new = "remote change\n" }, text(items[1]))
      end
      assert.are.equal("main", vim.trim(h.git(dir, { "branch", "--show-current" })))
      assert.are.equal("before", vim.fn.readfile(dir .. "/a.txt")[1])
      assert.are.equal("", h.git(dir, { "for-each-ref", "--format=%(refname)", "refs/heads/topic" }))
    end)
    vim.fn.delete(remote, "rf")
    assert(ok, reason)
  end)

  it("offers refs/index and fixed full commit SHAs through finite candidates", function()
    h.git(dir, { "tag", "v1" })
    local refs = assert(await(function(ctx)
      return Review.choices(ctx, dir, "ref", true)
    end))
    assert.are.equal("index", refs[1].revision)
    assert.are.same("refs/heads/main", refs[2].revision)
    assert.is_true(vim.tbl_contains(
      vim.tbl_map(function(c)
        return c.label
      end, refs),
      "refs/tags/v1"
    ))
    local commits = assert(await(function(ctx)
      return Review.choices(ctx, dir, "commit", false)
    end))
    assert.are.equal(1, #commits)
    assert.are.equal(vim.trim(h.git(dir, { "rev-parse", "HEAD" })), commits[1].revision)
  end)
end)
