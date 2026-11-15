---@module 'luassert'
---@diagnostic disable: duplicate-set-field

local Helpers = require("pigeon.helpers")
local Process = require("aviary.shared.process")

---@type fun(stdout: string, stderr?: string): aviary.shared.process.Result
local function result(stdout, stderr)
  return { code = stderr and 1 or 0, signal = 0, stdout = stdout, stderr = stderr or "" }
end

describe("aviary.pigeon.health", function()
  local saved_health, saved_has, saved_executable, saved_run, saved_tmux, saved_pane
  local reports, commands, executable, version, provider, source, receiver, bindings
  before_each(function()
    Helpers.reload_pigeon()
    saved_health, saved_has, saved_executable, saved_run = vim.health, vim.fn.has, vim.fn.executable, Process.run
    saved_tmux, saved_pane = vim.env.TMUX, vim.env.TMUX_PANE
    vim.env.TMUX, vim.env.TMUX_PANE = "/host,1,0", "%0"
    reports, commands, executable, provider, version = {}, {}, true, true, result("tmux 3.8")
    source, receiver, bindings = result("1\troot\tC-b\tNone\n"), nil, result("")
    local stub = {}
    for _, name in ipairs({ "start", "ok", "info", "warn", "error" }) do
      stub[name] = function(text)
        reports[#reports + 1] = { name, text }
      end
    end
    vim.health = setmetatable(stub, { __index = saved_health })
    vim.fn.has = function(name)
      return name == "clipboard" and (provider and 1 or 0) or saved_has(name)
    end
    vim.fn.executable = function(_command)
      return executable and 1 or 0
    end
    Process.run = function(args, _opts)
      commands[#commands + 1] = args
      if args[2] == "-V" then
        return version
      elseif args[2] == "display-message" then
        return source
      elseif args[2] == "list-keys" then
        if args[4] == "aviary-pigeon" then
          return receiver or result("", "table aviary-pigeon doesn't exist\n")
        end
        return bindings
      end
      error("unexpected health command: " .. vim.inspect(args))
    end
  end)
  after_each(function()
    vim.health, vim.fn.has, vim.fn.executable, Process.run = saved_health, saved_has, saved_executable, saved_run
    vim.env.TMUX, vim.env.TMUX_PANE = saved_tmux, saved_pane
    Helpers.reload_pigeon()
  end)

  it("checks the host without loading backends, acquiring resources or changing config", function()
    local Config = require("aviary.pigeon.config")
    local borrowed, snapshot, close_arg = Config(), vim.deepcopy(Config()), Config.tmux_close_arg
    require("aviary.pigeon.health").check()
    assert.are.same({ "ok", "clipboard: available" }, reports[3])
    assert.are.same({ "ok", "tmux: available" }, reports[4])
    assert.are.same({ "info", "tmux close key: show a receiver before checking key aliases" }, reports[5])
    assert.are.same({
      { "tmux", "-V" },
      { "tmux", "display-message", "-p", "-t", "%0", "#{session_attached}\t#{key-table}\t#{prefix}\t#{prefix2}" },
      { "tmux", "list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}", "C-." },
      { "tmux", "list-keys", "-T", "root", "-F", "#{key_string}" },
    }, commands)
    assert.is_true(rawequal(borrowed, Config()))
    assert.are.same(snapshot, Config())
    assert.are.equal(close_arg, Config.tmux_close_arg)
    assert.is_nil(package.loaded["aviary.pigeon.backends.tmux"])
    assert.is_nil(package.loaded["aviary.pigeon.backends.clipboard"])
  end)

  for _, missing in ipairs({ "TMUX", "TMUX_PANE", "both" }) do
    it("reports missing host context: " .. missing, function()
      if missing == "both" then
        vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
      else
        vim.env[missing] = nil
      end
      require("aviary.pigeon.health").check()
      assert.are.equal("info", reports[4][1])
      local names = missing == "both" and "TMUX and TMUX_PANE" or missing
      assert.is_truthy(reports[4][2]:find(names .. " not set", 1, true))
      assert.are.same({ { "tmux", "-V" } }, commands)
    end)
  end

  it("reports missing host context as an error when tmux is the default backend", function()
    require("aviary.pigeon.config").setup({ backend = { default = "tmux" } })
    vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
    require("aviary.pigeon.health").check()
    assert.are.equal("error", reports[4][1])
    assert.is_truthy(reports[4][2]:find("TMUX and TMUX_PANE not set", 1, true))
    assert.are.same({ { "tmux", "-V" } }, commands)
  end)

  it("reports an incompatible tmux version on the default backend", function()
    require("aviary.pigeon.config").setup({ backend = { default = "tmux" } })
    version = result("tmux 3.7")
    require("aviary.pigeon.health").check()
    assert.are.equal("error", reports[4][1])
    assert.is_truthy(reports[4][2]:find("tmux 3.8+", 1, true))
    assert.are.same({ { "tmux", "-V" } }, commands)
  end)

  it("reports missing dependencies and skips the version process when tmux is absent", function()
    provider, executable = false, false
    require("aviary.pigeon.health").check()
    assert.are.equal("error", reports[3][1])
    assert.are.equal("info", reports[4][1])
    assert.are.same({}, commands)
  end)

  for _, failure in ipairs({ "unrecognized version", "command failed" }) do
    it("reports version query failure: " .. failure, function()
      version = failure == "command failed" and result("", "version failure\n") or result("unknown")
      require("aviary.pigeon.health").check()
      assert.are.equal("info", reports[4][1])
      local reason = failure == "command failed" and "could not read tmux version: version failure"
        or "invalid tmux version"
      assert.is_truthy(reports[4][2]:find(reason, 1, true))
      assert.are.same({ { "tmux", "-V" } }, commands)
    end)
  end

  for _, conflict in ipairs({
    "C-.",
    "Any",
    "prefix",
    "prefix2",
    "alias",
    "alias-prefix",
    "semicolon",
    "meta-semicolon",
  }) do
    it("reports outer close-key conflicts in health: " .. conflict, function()
      local Config = require("aviary.pigeon.config")
      if conflict == "alias" or conflict == "alias-prefix" then
        Config.setup({ backend = { tmux = { close = "c-." } } })
      elseif conflict == "semicolon" or conflict == "meta-semicolon" then
        Config.setup({ backend = { tmux = { close = conflict == "semicolon" and ";" or "M-;" } } })
      end
      if conflict == "prefix" or conflict == "alias-prefix" then
        source = result("1\troot\tC-.\tNone\n")
      elseif conflict == "prefix2" then
        source = result("1\troot\tC-b\tC-.\n")
      end
      if conflict == "alias" or conflict == "alias-prefix" then
        receiver = result("C-.\n")
      end
      if conflict == "Any" then
        bindings = result("Any\n")
      elseif conflict ~= "prefix" and conflict ~= "prefix2" and conflict ~= "alias-prefix" then
        bindings = result((conflict == "alias" and "C-." or Config().backend.tmux.close) .. "\n")
      end
      local snapshot, close_arg = vim.deepcopy(Config()), Config.tmux_close_arg
      require("aviary.pigeon.health").check()
      assert.are.same(
        { "warn", "tmux close key is used by the outer tmux; choose another backend.tmux.close key" },
        reports[5]
      )
      assert.are.same(snapshot, Config())
      assert.are.equal(close_arg, Config.tmux_close_arg)
      assert.are.equal(close_arg, commands[3][#commands[3]])
      for _, args in ipairs(commands) do
        assert.is_true(args[2] == "-V" or args[2] == "display-message" or args[2] == "list-keys")
      end
    end)
  end

  it("inspects the current outer key table", function()
    source, bindings = result("1\tcustom\tC-b\tNone\n"), result("C-.\n")
    require("aviary.pigeon.health").check()
    assert.are.equal("warn", reports[5][1])
    assert.are.equal("custom", commands[4][4])
  end)

  it("does not treat a receiver close binding as an outer conflict", function()
    local Config = require("aviary.pigeon.config")
    Config.setup({ backend = { tmux = { close = "c-." } } })
    receiver, bindings = result("C-.\n"), result("F11\n")
    require("aviary.pigeon.health").check()
    assert.are.equal("ok", reports[5][1])
    assert.are.equal("c-.", Config().backend.tmux.close)
    assert.are.equal("c-.", Config.tmux_close_arg)
  end)

  it("uses the original key when the receiver table has no binding", function()
    receiver = result("", "unknown key: C-.\n")
    source = result("1\troot\tC-.\tNone\n")
    require("aviary.pigeon.health").check()
    assert.are.equal("warn", reports[5][1])
    assert.is_truthy(reports[5][2]:find("used by the outer tmux", 1, true))
  end)

  for _, conflict in ipairs({ "binding", "prefix" }) do
    it("does not rule out alias conflicts before the first receiver binding: " .. conflict, function()
      require("aviary.pigeon.config").setup({ backend = { tmux = { close = "c-." } } })
      if conflict == "binding" then
        bindings = result("C-.\n")
      else
        source = result("1\troot\tC-.\tNone\n")
      end
      require("aviary.pigeon.health").check()
      assert.are.same({ "info", "tmux close key: show a receiver before checking key aliases" }, reports[5])
    end)
  end

  for _, failure in ipairs({ "query failed", "no attached client" }) do
    it("reports unavailable outer context: " .. failure, function()
      source = failure == "query failed" and result("", "context failure\n") or result("0\troot\tC-b\tNone\n")
      require("aviary.pigeon.health").check()
      assert.are.equal("warn", reports[5][1])
      local reason = failure == "query failed" and "could not inspect outer tmux: context failure"
        or "tmux source session has no attached client"
      assert.are.equal(reason, reports[5][2])
      assert.are.equal(2, #commands)
    end)
  end

  it("reports outer binding query errors diagnostically", function()
    bindings = result("", "binding query failed\n")
    require("aviary.pigeon.health").check()
    assert.are.same({ "warn", "could not inspect outer tmux bindings: binding query failed" }, reports[5])
  end)
end)
