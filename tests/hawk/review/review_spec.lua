---@module 'luassert'

local Async = require("aviary.shared.async")
local Git = require("aviary.hawk.git")
local Row = require("aviary.hawk.snapshot.row")
local h = require("hawk.helpers")

local function await(work)
  local finished, result, reason = false, nil, nil
  Async.run(function(ctx)
    result, finished = work(ctx), true
  end, function(err)
    reason, finished = err, true
  end)
  h.wait_for(function()
    return finished
  end)
  return result, reason
end

local function paths(entries)
  return vim.tbl_map(function(entry)
    return entry.path
  end, entries)
end

describe("Review Git object comparisons", function()
  local dir, cwd, source, base, remote
  local label_ns = vim.api.nvim_create_namespace("aviary.test.hawk.label")
  local value_ns = vim.api.nvim_create_namespace("aviary.test.hawk.value")

  before_each(function()
    source, cwd = vim.api.nvim_get_current_win(), vim.fn.getcwd(-1, -1)
    dir, remote = h.repo(), nil
    vim.cmd.cd(dir)
    h.write(dir, "a.txt", { "before" })
    h.write(dir, "b.txt", { "other" })
    h.commit(dir)
    base = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
  end)

  after_each(function()
    vim.cmd.cd(cwd)
    h.cleanup(source, dir)
    h.flush()
    if remote then
      vim.fn.delete(remote, "rf")
    end
  end)

  local function read(old, new)
    return await(function(ctx)
      return Git.diff(ctx, dir, old or base, new or "HEAD")
    end)
  end

  local function text(entry)
    return assert(await(function(ctx)
      return Git.versions(ctx, dir, entry.old_blob, entry.new_blob)
    end))
  end

  it("resolves HEAD on refresh and keeps previously captured blobs, including in detached HEAD", function()
    h.write(dir, "a.txt", { "next" })
    h.commit(dir)
    local first = assert(read())[1]
    h.git(dir, { "checkout", "--detach", "HEAD" })
    h.write(dir, "a.txt", { "detached" })
    h.commit(dir)
    assert.are.same({ old = "before\n", new = "detached\n" }, text(assert(read())[1]))
    assert.are.same({ old = "before\n", new = "next\n" }, text(first))
    assert.are.same({ old = "before\n", new = "next\n" }, text(assert(read(base, "main"))[1]))
  end)

  it("reports an error when HEAD has no commit", function()
    h.git(dir, { "checkout", "--orphan", "unborn" })
    local entries, reason = read()
    assert.is_nil(entries)
    assert.matches("HEAD", assert(reason))
  end)

  it("compares committed versions and sorts exact paths despite staged and working-tree changes", function()
    h.write(dir, "a.txt", { "committed" })
    h.write(dir, "z\tline\n.txt", { "new" })
    h.commit(dir)
    h.write(dir, "a.txt", { "staged" })
    h.write(dir, "stage-only.txt", { "exclude" })
    h.git(dir, { "add", "a.txt", "stage-only.txt" })
    h.write(dir, "a.txt", { "unstaged" })
    h.write(dir, "untracked", { "exclude" })
    local entries = assert(read())
    assert.are.same({ "a.txt", "z\tline\n.txt" }, paths(entries))
    assert.are.same({ old = "before\n", new = "committed\n" }, text(entries[1]))
    assert.are.same({ old = "", new = "new\n" }, text(entries[2]))
    assert.are.equal("[ ] A z line .txt +1 -0", Row.diff(entries[2]):render(label_ns, value_ns).text)
  end)

  it("compares the requested revisions directly or from their merge base", function()
    h.git(dir, { "checkout", "-qb", "side" })
    h.write(dir, "side.txt", { "side" })
    h.commit(dir)
    h.git(dir, { "checkout", "-q", "main" })
    h.write(dir, "main.txt", { "main" })
    h.commit(dir)

    local tab = h.open()
    h.edit_input(1, "side")
    h.edit_input(2, "main")
    h.press("r")
    h.wait_for(function()
      return #h.lines(tab.bufnr) == 4
    end)
    assert.are.same({ "side", "main", "[ ] A main.txt +1 -0", "[ ] D side.txt +0 -1" }, h.lines(tab.bufnr))

    tab:to("merge")
    assert.are.same({ "side", "main" }, h.lines(tab.bufnr))
    h.write(dir, "stage-only.txt", { "exclude" })
    h.git(dir, { "add", "stage-only.txt" })
    h.press("r")
    h.wait_for(function()
      return #h.lines(tab.bufnr) == 3
    end)
    assert.are.same({ "side", "main", "[ ] A main.txt +1 -0" }, h.lines(tab.bufnr))
  end)

  it("retains both rename paths and describes their byte highlight ranges", function()
    local path = "long-directory/中文文件.txt"
    vim.fn.mkdir(dir .. "/long-directory", "p")
    h.git(dir, { "mv", "a.txt", path })
    h.commit(dir)
    local row = Row.diff(assert(read())[1])
    local display = row:render(label_ns, value_ns)
    assert.are.equal("[ ] R a.txt → " .. path .. " +0 -0", display.text)
    assert.are.same(
      {
        { "[ ]", "Normal" },
        { "R", "Changed" },
        { "a.txt → " .. path, "Directory" },
        { "+0", "Added" },
        { "-0", "Removed" },
      },
      vim.tbl_map(function(mark)
        return { display.text:sub(mark.column + 1, mark.opts.end_col), mark.opts.hl_group }
      end, display.marks)
    )
    assert.are.equal(path, row.path)
    assert.are.equal("a.txt", row.old_path)
  end)

  it("caps displayed counts at 10k+ while preserving the actual counts", function()
    for _, count in ipairs({ 9999, 10000 }) do
      h.write(dir, "a.txt", vim.split(string.rep("new\n", count), "\n", { trimempty = true }))
      h.commit(dir)
      local row = Row.diff(assert(read())[1])
      local display = row:render(label_ns, value_ns)
      local added = count == 10000 and "+10k+" or "+9999"
      assert.are.equal("[ ] M a.txt " .. added .. " -1", display.text)
      assert.are.equal(count, row.added)
      assert.are.equal(1, row.removed)
      local mark = display.marks[4]
      assert.are.equal(added, display.text:sub(mark.column + 1, mark.opts.end_col))
    end
  end)

  it("represents deleted, empty, binary, and mode-only files", function()
    h.git(dir, { "rm", "b.txt" })
    h.write(dir, "empty.txt", {})
    local file = assert(io.open(dir .. "/binary.dat", "wb"))
    file:write("x\000y")
    file:close()
    h.git(dir, { "add", "-A" })
    h.git(dir, { "update-index", "--chmod=+x", "a.txt" })
    h.git(dir, { "commit", "-qm", "file changes" })
    local entries = assert(read())
    assert.are.same({ "a.txt", "b.txt", "binary.dat", "empty.txt" }, paths(entries))
    assert.are.equal("[ ] M a.txt +0 -0", Row.diff(entries[1]):render(label_ns, value_ns).text)
    assert.are.equal("D", entries[2].status)
    assert.is_nil(entries[2].new_blob)
    assert.are.same({ old = "other\n", new = "" }, text(entries[2]))
    assert.are.equal("binary", entries[3].kind)
    assert.is_nil(entries[3].added)
    assert.are.equal("[ ] A binary.dat — —", Row.diff(entries[3]):render(label_ns, value_ns).text)
    assert.are.equal(0, entries[4].added)
  end)

  it("keeps a submodule commit in a non-text row", function()
    h.git(dir, { "update-index", "--add", "--cacheinfo", "160000," .. base .. ",module" })
    h.git(dir, { "commit", "-qm", "submodule" })
    local entry = assert(read())[1]
    assert.are.equal("submodule", entry.kind)
    assert.are.equal(base, entry.new_blob)
    assert.are.equal("[ ] A module — —", Row.diff(entry):render(label_ns, value_ns).text)
  end)

  it("compares remote branches and annotated tags without checking them out", function()
    remote = dir .. "-remote"
    h.git(dir, { "clone", "-q", dir, remote })
    h.git(remote, { "config", "user.email", "test@example.com" })
    h.git(remote, { "config", "user.name", "test" })
    h.git(remote, { "checkout", "-qb", "topic" })
    h.write(remote, "a.txt", { "remote change" })
    h.commit(remote)
    h.git(remote, { "tag", "-a", "remote-tag", "-m", "review" })
    h.git(dir, { "remote", "add", "origin", remote })
    h.git(dir, { "fetch", "-q", "origin", "--tags" })
    for _, ref in ipairs({ "refs/remotes/origin/topic", "refs/tags/remote-tag" }) do
      local entries = assert(read("refs/heads/main", ref))
      assert.are.same({ "a.txt" }, paths(entries))
      assert.are.same({ old = "before\n", new = "remote change\n" }, text(entries[1]))
    end
    assert.are.equal("main", vim.trim(h.git(dir, { "branch", "--show-current" })))
    assert.are.equal("before", vim.fn.readfile(dir .. "/a.txt")[1])
    assert.are.equal("", h.git(dir, { "for-each-ref", "--format=%(refname)", "refs/heads/topic" }))
  end)
end)
