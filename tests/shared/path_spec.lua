---@module 'luassert'

local Path = require("aviary.shared.path")

describe("aviary.shared.path", function()
  describe("relpath", function()
    it("relativizes a descendant", function()
      assert.are.equal("a/b.lua", Path.relpath("/tmp/exporter", "/tmp/exporter/a/b.lua"))
    end)

    it("keeps a path that escapes the base absolute", function()
      assert.are.equal("/etc/passwd", Path.relpath("/tmp/exporter", "/etc/passwd"))
    end)

    it("keeps the base itself absolute", function()
      assert.are.equal("/tmp/exporter", Path.relpath("/tmp/exporter", "/tmp/exporter"))
    end)

    it("keeps the path unchanged when there is no base", function()
      assert.are.equal("/etc/passwd", Path.relpath(nil, "/etc/passwd"))
      assert.are.equal("/etc/passwd", Path.relpath("", "/etc/passwd"))
    end)

    it("does not treat a sibling with a shared prefix as a descendant", function()
      assert.are.equal("/tmp/exporter-other/a.lua", Path.relpath("/tmp/exporter", "/tmp/exporter-other/a.lua"))
    end)

    it("tolerates a base spelled with a trailing slash", function()
      assert.are.equal("a/b.lua", Path.relpath("/tmp/exporter/", "/tmp/exporter/a/b.lua"))
    end)
  end)

  describe("tilde", function()
    it("folds the home directory and leaves everything else alone", function()
      local home = vim.fn.getenv("HOME")
      if home == nil or home == vim.NIL or home == "" then
        return
      end
      assert.are.equal("~", Path.tilde(home))
      assert.are.equal("~/x", Path.tilde(home .. "/x"))
      assert.are.equal("/etc/passwd", Path.tilde("/etc/passwd"))
    end)
  end)

  describe("truncate", function()
    it("keeps fitting paths and their spelling unchanged", function()
      for _, path in ipairs({ "", "/", "~/a.lua", "C:/src/a.lua", "src/", "src/a.lua" }) do
        assert.are.equal(path, Path.truncate(path, vim.fn.strdisplaywidth(path)))
      end
    end)

    it("omits whole directories while restoring trailing and then leading segments", function()
      local path = "lua/aviary/shared/util/path.lua"
      assert.are.equal("lua/…/util/path.lua", Path.truncate(path, 22))
      assert.are.equal("…/path.lua", Path.truncate(path, 12))
      assert.are.equal("/path/to/…/file.lua", Path.truncate("/path/to/long_name_directory/file.lua", 19))
      assert.are.equal("a/…/d/e/f.lua", Path.truncate("a/long_directory/c/d/e/f.lua", 13))
    end)

    it("drops directories before shortening an oversized filename", function()
      local path = "lua/aviary/shared/util/path.lua"
      assert.are.equal("path.lua", Path.truncate(path, 8))
      assert.are.equal("pa…lua", Path.truncate(path, 6))
      assert.are.equal("pa…lua", Path.truncate("path.lua", 6))
      assert.are.equal("…/a.lua", Path.truncate("long_directory/a.lua", 7))
      assert.are.equal("…", Path.truncate("path.lua", 0))
      assert.are.equal("…", Path.truncate("/", 0))
    end)

    it("retains absolute, HOME and normalized drive prefixes when they fit", function()
      assert.are.equal("/path/…/file.lua", Path.truncate("/path/long_directory/file.lua", 16))
      assert.are.equal("~/…/file.lua", Path.truncate("~/long_directory/file.lua", 12))
      assert.are.equal("C:/src/…/file.lua", Path.truncate("C:/src/long_directory/file.lua", 17))
    end)

    it("never cuts directory names, including an oversized trailing directory", function()
      assert.are.equal("a/…/dir/", Path.truncate("a/long_directory/dir/", 8))
      assert.are.equal("…/", Path.truncate("a/very_long_directory/", 4))
      assert.are.equal("…", Path.truncate("a/very_long_directory/", 1))
    end)

    it("counts display cells and preserves composing characters", function()
      assert.are.equal("中/…/é.txt", Path.truncate("中/long_directory/é.txt", 10))
      assert.are.equal("éa…gh", Path.truncate("long_directory/éabcdefgh", 5))
    end)

    it("accounts for a double-width ellipsis", function()
      local previous = vim.o.ambiwidth
      vim.o.ambiwidth = "double"
      local ok, reason = pcall(function()
        assert.are.equal("a/…/file.lua", Path.truncate("a/long_directory/file.lua", 13))
        assert.are.equal("…/file.lua", Path.truncate("a/long_directory/file.lua", 12))
        assert.are.equal("…", Path.truncate("long_directory/", 0))
      end)
      vim.o.ambiwidth = previous
      assert(ok, reason)
    end)

    it("respects every width budget and keeps all displayed directories whole", function()
      for _, path in ipairs({
        "a/b/c.lua",
        "lua/aviary/shared/util/path.lua",
        "/path/to/long_name_directory/file.lua",
        "~/中文/目录/file.lua",
        "C:/src/long_directory/",
        "a/very_long_directory/",
      }) do
        local directories = {}
        for part in path:gmatch("([^/]+)/") do
          directories[part] = true
        end
        for width = 0, vim.fn.strdisplaywidth(path) + 1 do
          local shortened = Path.truncate(path, width)
          assert.is_true(vim.fn.strdisplaywidth(shortened) <= math.max(width, vim.fn.strdisplaywidth("…")))
          for part in shortened:gmatch("([^/]+)/") do
            assert.is_true(part == "…" or directories[part] == true)
          end
        end
      end
    end)
  end)
end)

describe("global cwd and Git worktree root", function()
  local dir, cwd
  before_each(function()
    cwd = vim.fn.getcwd(-1, -1)
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/repo/sub", "p")
    vim.fn.mkdir(dir .. "/local", "p")
    vim.fn.mkdir(dir .. "/tab", "p")
  end)
  after_each(function()
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, "rf")
  end)

  it("ignores lcd/tcd and finds a directory marker above global cwd", function()
    vim.fn.mkdir(dir .. "/repo/.git")
    vim.cmd.cd(dir .. "/repo/sub")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir .. "/tab"))
    vim.cmd("lcd " .. vim.fn.fnameescape(dir .. "/local"))
    assert.are.equal(dir .. "/repo/sub", Path.cwd())
    assert.are.equal(dir .. "/repo", Path.git())
  end)

  it("recognizes a git file and reports absence instead of returning cwd", function()
    vim.fn.writefile({ "gitdir: ../main/.git/worktrees/test" }, dir .. "/repo/.git")
    vim.cmd.cd(dir .. "/repo/sub")
    assert.are.equal(dir .. "/repo", Path.git())
    vim.cmd.cd(dir .. "/local")
    local value, reason = Path.git()
    assert.is_nil(value)
    assert.is_string(reason)
  end)

  it("resolves repository presence again without a cwd change", function()
    vim.cmd.cd(dir .. "/repo/sub")
    assert.is_nil(Path.git())
    vim.fn.mkdir(dir .. "/repo/.git")
    assert.are.equal(dir .. "/repo", Path.git())
  end)
end)
