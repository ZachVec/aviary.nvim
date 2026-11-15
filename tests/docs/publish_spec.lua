---@module 'luassert'

local publisher = vim.fs.joinpath(vim.uv.cwd(), "scripts/publish-docs")

describe("Vimdoc publication", function()
  local dir, origin, author, checkout, artifacts, tested_head

  local function run(args, cwd)
    return vim.system(args, { cwd = cwd, text = true }):wait(10000)
  end

  local function git(cwd, ...)
    local result = run({ "git", "-C", cwd, ... })
    assert.are.equal(0, result.code, result.stderr)
    return vim.trim(result.stdout)
  end

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  local function publish()
    return run({ "bash", publisher, artifacts, "main", tested_head }, checkout)
  end

  local function advance_author()
    write(author .. "/source.txt", { "new source" })
    git(author, "add", "source.txt")
    git(author, "commit", "-m", "change source")
    return git(author, "rev-parse", "HEAD")
  end

  before_each(function()
    dir = vim.fn.tempname()
    origin, author, checkout, artifacts = dir .. "/origin", dir .. "/author", dir .. "/checkout", dir .. "/artifacts"
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "--bare", "--initial-branch=main", origin)
    git(dir, "clone", origin, author)
    git(author, "config", "user.name", "Docs test")
    git(author, "config", "user.email", "docs@example.invalid")
    git(author, "config", "commit.gpgsign", "false")
    write(author .. "/source.txt", { "validated source" })
    write(author .. "/doc/sample.nvim.txt", { "old help" })
    write(author .. "/doc/notes.txt", { "unrelated help" })
    git(author, "add", ".")
    git(author, "commit", "-m", "validated source")
    git(author, "push", "origin", "main")
    tested_head = git(author, "rev-parse", "HEAD")
    git(dir, "clone", origin, checkout)
    git(checkout, "checkout", "--detach", tested_head)
    git(checkout, "config", "commit.gpgsign", "false")
    write(artifacts .. "/sample.nvim.txt", { "generated help" })
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("commits only generated help on top of the validated commit", function()
    local result = publish()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal(tested_head, git(origin, "rev-parse", "main^"))
    assert.are.equal("doc/sample.nvim.txt", git(origin, "diff-tree", "--no-commit-id", "--name-only", "-r", "main"))
    assert.are.equal("generated help", git(origin, "show", "main:doc/sample.nvim.txt"))
    assert.are.equal("docs: regenerate Vimdoc [skip ci]", git(origin, "log", "-1", "--format=%s", "main"))
  end)

  it("does not commit unchanged help", function()
    write(artifacts .. "/sample.nvim.txt", { "old help" })
    local result = publish()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal(tested_head, git(origin, "rev-parse", "main"))
    assert.are.equal(tested_head, git(checkout, "rev-parse", "HEAD"))
  end)

  it("skips results when the branch advanced before publication", function()
    local next_head = advance_author()
    git(author, "push", "origin", "main")
    local result = publish()
    assert.are.equal(0, result.code, result.stderr)
    assert.is_truthy(result.stdout:find("Skipping Vimdoc publication", 1, true))
    assert.are.equal(next_head, git(origin, "rev-parse", "main"))
    assert.are.equal("old help", git(origin, "show", "main:doc/sample.nvim.txt"))
    assert.are.equal(tested_head, git(checkout, "rev-parse", "HEAD"))
  end)

  it("skips a rejected push when another commit wins the race", function()
    local next_head = advance_author()
    local hook = checkout .. "/.git/hooks/pre-push"
    write(hook, { "#!/bin/sh", "exec git -C " .. vim.fn.shellescape(author) .. " push origin main" })
    vim.fn.setfperm(hook, "rwx------")
    local result = publish()
    assert.are.equal(0, result.code, result.stderr)
    assert.is_truthy(result.stdout:find("advanced during the push", 1, true))
    assert.are.equal(next_head, git(origin, "rev-parse", "main"))
    assert.are.equal("old help", git(origin, "show", "main:doc/sample.nvim.txt"))
  end)

  it("reports other push failures", function()
    local hook = origin .. "/hooks/pre-receive"
    write(hook, { "#!/bin/sh", "echo 'publication rejected by server' >&2", "exit 1" })
    vim.fn.setfperm(hook, "rwx------")
    local result = publish()
    assert.are.equal(1, result.code)
    assert.is_truthy(result.stderr:find("publication rejected by server", 1, true))
    assert.is_truthy(result.stderr:find("publication failed", 1, true))
    assert.are.equal(tested_head, git(origin, "rev-parse", "main"))
  end)

  it("reports a remote lookup failure instead of treating it as branch advancement", function()
    git(checkout, "remote", "set-url", "origin", dir .. "/missing")
    local result = publish()
    assert.is_not.equal(0, result.code)
    assert.is_nil(result.stdout:find("Skipping", 1, true))
    assert.are.equal(tested_head, git(checkout, "rev-parse", "HEAD"))
  end)

  it("rejects artifacts outside the help-file convention", function()
    write(artifacts .. "/unexpected.sh", { "exit 99" })
    local result = publish()
    assert.are.equal(1, result.code)
    assert.is_truthy(result.stderr:find("Unexpected Vimdoc artifact", 1, true))
    assert.are.equal(tested_head, git(origin, "rev-parse", "main"))
    assert.are.equal("", git(checkout, "status", "--porcelain"))
  end)

  it("publishes deletions without touching unrelated help files", function()
    vim.fn.delete(artifacts .. "/sample.nvim.txt")
    write(artifacts .. "/aviary.nvim.txt", { "main help" })
    local result = publish()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal("", git(origin, "ls-tree", "--name-only", "main", "doc/sample.nvim.txt"))
    assert.are.equal("main help", git(origin, "show", "main:doc/aviary.nvim.txt"))
    assert.are.equal("unrelated help", git(origin, "show", "main:doc/notes.txt"))
  end)
end)
