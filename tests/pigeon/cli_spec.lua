---@module 'luassert'

local Helpers = require("pigeon.helpers")
local Process = require("aviary.shared.process")

describe("pigeon tmux resource operations", function()
  local Cli, saved_run, saved_origin, saved_tmux, calls, respond, displays
  local host_socket = "/tmp/aviary-host,with-comma"
  local function fails(fn, message)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find(message, 1, true))
  end
  local function result(output, code, stderr)
    return { code = code or 0, signal = 0, stdout = output or "", stderr = stderr or "" }
  end
  before_each(function()
    Helpers.reload_pigeon()
    Cli = require("aviary.pigeon.backends.tmux.cli")
    calls, displays = {}, {}
    saved_run, saved_origin, saved_tmux = Process.run, vim.env.TMUX_PANE, vim.env.TMUX
    vim.env.TMUX_PANE = "%0"
    vim.env.TMUX = host_socket .. ",123,0"
    local generation = 26
    respond = function(call, _opts)
      if call.command == "list-panes" then
        return result(displays[vim.env.TMUX_PANE] or "")
      end
      if call.command == "new-pane" then
        generation = generation + 1
        return result("%" .. generation .. "\n")
      end
      if call.command == "set-option" and call.args[6] == "@pigeon_source" then
        displays[call.args[7]] = call.args[5]
      end
      if call.command == "kill-pane" then
        for origin, pane in pairs(displays) do
          if pane == call.args[#call.args] then
            displays[origin] = nil
          end
        end
      end
      return result()
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    Process.run = function(args, opts)
      assert.are.equal("tmux", args[1])
      assert.are_not.equal("-", args[2]:sub(1, 1))
      assert.is_false(vim.tbl_contains(args, ";"))
      assert.is_false(vim.tbl_contains(args, "-L"))
      assert.is_false(vim.tbl_contains(args, "/dev/null"))
      assert.is_false(opts.text)
      assert.is_nil(opts.env)
      local call = { args = args, command = args[2], tmux = vim.env.TMUX }
      calls[#calls + 1] = call
      if call.command ~= "respawn-pane" then
        assert.is_false(vim.tbl_contains(args, "-S"))
      end
      return respond(call, opts)
    end
  end)
  after_each(function()
    Process.run, vim.env.TMUX_PANE, vim.env.TMUX = saved_run, saved_origin, saved_tmux
    Helpers.reload_pigeon()
  end)

  it("filters receivers and returns length-framed instance, tool and launch directory fields", function()
    local cwd = "/路径/tab\tline\nnext"
    respond = function()
      return result("3:abc5:codex" .. #cwd .. ":" .. cwd .. "\n3:def6:claude4:/tmp\n")
    end
    assert.are.same({
      { name = "abc", tool = "codex", cwd = cwd },
      { name = "def", tool = "claude", cwd = "/tmp" },
    }, Cli.list())
    assert.are.equal(1, #calls)
    assert.are.same({
      "tmux",
      "list-sessions",
      "-f",
      "#{!=:#{@pigeon_tool},}",
      "-F",
      "#{n:session_name}:#{session_name}#{n:@pigeon_tool}:#{@pigeon_tool}#{n:pane_start_path}:#{pane_start_path}",
    }, calls[1].args)
  end)

  it("accepts empty successful stdout without treating warning stderr as an error", function()
    respond = function()
      return result("", 0, "warning output\n")
    end
    assert.is_nil(Cli.paste("=abc:", "draft"))
    assert.are.same({}, Cli.list())
  end)

  it("raises raw stderr on failure even when stdout is nonempty", function()
    respond = function()
      return result("partial output", 1, "native failure\n")
    end
    fails(function()
      Cli.paste("=abc:", "draft")
    end, "native failure\n")
  end)

  it("inherits the current TMUX environment for each operation", function()
    Cli.list()
    local changed = "/tmp/changed-server,456,1"
    vim.env.TMUX = changed
    Cli.list()
    assert.are.same({ host_socket .. ",123,0", changed }, { calls[1].tmux, calls[2].tmux })
    assert.are.same(calls[1].args, calls[2].args)
  end)

  it("creates before configuring with separate commands and literal argv", function()
    Cli.create(
      "abc",
      "tool#{name};",
      { "agent", "a;", "#{session_name}" },
      "/agent/#{session_name};",
      { ["@custom"] = "metadata#{session_name};" }
    )
    assert.are.equal(3, #calls)
    assert.are.equal("new-session", calls[1].command)
    assert.is_true(vim.tbl_contains(calls[1].args, "/agent/##{session_name}\\;"))
    assert.is_true(vim.tbl_contains(calls[1].args, "a\\;"))
    assert.is_true(vim.tbl_contains(calls[1].args, "tool##{name}\\;"))
    assert.is_true(vim.tbl_contains(calls[1].args, "#{session_name}"))
    assert.are.same({ "tmux", "set-option", "-w", "-t", "=abc:", "remain-on-exit", "off" }, calls[2].args)
    assert.are.same({ "tmux", "set-option", "-t", "=abc:", "@custom", "metadata#{session_name}\\;" }, calls[3].args)
  end)

  it("does not release an unacquired session", function()
    respond = function()
      return result("", 1, "session already exists")
    end
    local ok, why = pcall(Cli.create, "abc", "agent", { "agent" }, "/agent", {})
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("session already exists", 1, true))
    assert.are.equal(1, #calls)
  end)

  it("rolls back the acquired session by name and ignores cleanup errors", function()
    respond = function(call)
      if call.command == "set-option" then
        return result("", 1, "configuration failed")
      end
      if call.command == "kill-session" then
        return result("", 1, "cleanup failed")
      end
      return result()
    end
    local ok, why = pcall(Cli.create, "abc", "agent", { "agent" }, "/agent", {})
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("configuration failed", 1, true))
    assert.is_nil(tostring(why):find("cleanup failed", 1, true))
    assert.are.same({ "tmux", "kill-session", "-t", "=abc" }, calls[3].args)
  end)

  it("configures the shared key table and receiver before acquiring its display", function()
    Cli.focus("abc")
    local expected = {
      { "tmux", "bind-key", "-T", "aviary-pigeon", "C-.", "detach-client" },
      { "tmux", "unbind-key", "-a", "-T", "aviary-pigeon" },
      { "tmux", "bind-key", "-T", "aviary-pigeon", "C-.", "detach-client" },
      { "tmux", "set-option", "-t", "=abc:", "key-table", "aviary-pigeon" },
    }
    for index, args in ipairs(expected) do
      assert.are.same(args, calls[index].args)
    end
    assert.are.equal("list-panes", calls[5].command)
    for _, call in ipairs(calls) do
      assert.are_not.equal("has-session", call.command)
      if call.command == "respawn-pane" then
        assert.are.same({
          "tmux",
          "respawn-pane",
          "-k",
          "-t",
          "%27",
          "--",
          "env",
          "-u",
          "TMUX",
          "tmux",
          "-S",
          host_socket,
          "attach-session",
          "-t",
          "=abc",
        }, call.args)
      end
    end
  end)

  it("queries the source window and reuses its marked float on every focus", function()
    Cli.focus("abc")
    calls = {}
    Cli.focus("other")
    local queries, attached = 0, nil
    for _, call in ipairs(calls) do
      assert.are_not.equal("new-pane", call.command)
      assert.are_not.equal("kill-pane", call.command)
      if call.command == "list-panes" then
        queries = queries + 1
        assert.are.same(
          { "-t", "%0", "-f", "#{&&:#{pane_floating_flag},#{==:#{@pigeon_source},%0}}", "-F", "#{pane_id}" },
          vim.list_slice(call.args, 3)
        )
      elseif call.command == "respawn-pane" then
        attached = call
      elseif call.command == "resize-pane" then
        assert.is_true(vim.tbl_contains(call.args, "90%"))
      elseif call.command == "set-hook" then
        assert.is_false(vim.tbl_contains(call.args, "-a"))
        assert.is_false(vim.tbl_contains(call.args, "-R"))
      end
    end
    assert.are.equal(1, queries)
    assert.is_true(vim.tbl_contains(assert(attached).args, "%27"))
    assert.is_true(vim.tbl_contains(assert(attached).args, "=other"))
  end)

  it("creates separate marked floats for different sources in one window", function()
    Cli.focus("abc")
    vim.env.TMUX_PANE = "%1"
    calls = {}
    Cli.focus("abc")
    assert.are.same({ ["%0"] = "%27", ["%1"] = "%28" }, displays)
    for _, call in ipairs(calls) do
      assert.are_not.equal("kill-pane", call.command)
    end
  end)

  it("detects a dead receiver when setting its key table before acquiring a display", function()
    respond = function(call)
      return result("", call.command == "set-option" and 1 or 0, "can't find session: abc")
    end
    fails(function()
      Cli.focus("abc")
    end, "can't find session: abc")
    assert.are.equal(4, #calls)
    assert.are.same({ "tmux", "set-option", "-t", "=abc:", "key-table", "aviary-pigeon" }, calls[4].args)
  end)

  it("rolls back an existing float when reuse fails without creating a replacement", function()
    Cli.focus("abc")
    calls = {}
    local original = respond
    respond = function(call, opts)
      if call.command == "move-pane" then
        return result("", 1, "can't find pane: %27")
      end
      return original(call, opts)
    end
    fails(function()
      Cli.focus("abc")
    end, "can't find pane: %27")
    assert.is_nil(displays["%0"])
    assert.are.same({ "tmux", "kill-pane", "-t", "%27" }, calls[#calls].args)
    for _, call in ipairs(calls) do
      assert.are_not.equal("new-pane", call.command)
    end
  end)

  for _, failed in ipairs({ "list-panes", "new-pane" }) do
    it("does not release an unacquired display after " .. failed .. " failure", function()
      local original = respond
      respond = function(call, opts)
        if call.command == failed then
          return result("", 1, "acquisition failed")
        end
        return original(call, opts)
      end
      fails(function()
        Cli.focus("abc")
      end, "acquisition failed")
      for _, call in ipairs(calls) do
        assert.are_not.equal("kill-pane", call.command)
      end
    end)
  end

  for _, case in ipairs({
    { mode = "new", command = "set-option", option = "@pigeon_source", reason = "pane configuration failed" },
    { mode = "reused", command = "respawn-pane", reason = "attach failed" },
  }) do
    it("rolls back a " .. case.mode .. " float on " .. case.command .. " failure and allows retrying", function()
      if case.mode == "reused" then
        Cli.focus("abc")
      end
      calls = {}
      local original = respond
      respond = function(call, opts)
        if call.command == case.command and (not case.option or call.args[6] == case.option) then
          return result("", 1, case.reason)
        end
        return original(call, opts)
      end
      fails(function()
        Cli.focus("abc")
      end, case.reason)
      local cleanup = calls[#calls]
      assert.are.equal("kill-pane", cleanup.command)
      local released = cleanup.args[#cleanup.args]
      assert.is_nil(displays["%0"])
      for _, call in ipairs(calls) do
        assert.are_not.equal("select-pane", call.command)
      end
      respond, calls = original, {}
      assert.is_nil(Cli.focus("abc"))
      assert.is_not_nil(displays["%0"])
      assert.are_not.equal(released, displays["%0"])
    end)
  end

  it("preserves the focus error when display cleanup also fails", function()
    Cli.focus("abc")
    local original = respond
    respond = function(call, opts)
      if call.command == "resize-pane" then
        return result("", 1, "resize failed")
      end
      if call.command == "kill-pane" then
        return result("", 1, "cleanup failed")
      end
      return original(call, opts)
    end
    local ok, why = pcall(Cli.focus, "abc")
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("resize failed", 1, true))
    assert.is_nil(tostring(why):find("cleanup failed", 1, true))
    assert.are.equal("kill-pane", calls[#calls].command)
  end)

  it("recreates a float after it was closed outside Neovim", function()
    Cli.focus("abc")
    displays["%0"] = nil
    calls = {}
    Cli.focus("abc")
    assert.are.equal("%28", displays["%0"])
    for _, call in ipairs(calls) do
      assert.are_not.equal("kill-pane", call.command)
    end
  end)

  for _, failed in ipairs({ "load-buffer", "paste-buffer" }) do
    it("stops at " .. failed .. " failure without closing the display", function()
      assert.is_nil(Cli.focus("abc"))
      calls = {}
      local text = "draft\n#{};"
      respond = function(call, opts)
        if call.command == "load-buffer" then
          assert.are.equal(text, opts.stdin)
        elseif call.command == "paste-buffer" then
          assert.is_nil(opts.stdin)
          assert.is_false(opts.text)
        elseif call.command == "kill-pane" then
          return result("", 1, "cleanup failed")
        end
        return result("", call.command == failed and 1 or 0, "write failed")
      end
      fails(function()
        Cli.paste("=abc:", text)
      end, "write failed")
      local expected = failed == "load-buffer" and { "load-buffer" } or { "load-buffer", "paste-buffer" }
      local actual = {}
      for _, call in ipairs(calls) do
        actual[#actual + 1] = call.command
      end
      assert.are.same(expected, actual)
      respond, calls = function()
        return result()
      end, {}
      assert.is_nil(Cli.paste("=abc:", text))
      assert.are.equal("load-buffer", calls[1].command)
      assert.are.equal("paste-buffer", calls[2].command)
      assert.are.equal("%27", displays["%0"])
    end)
  end
end)
