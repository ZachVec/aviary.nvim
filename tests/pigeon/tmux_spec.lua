---@module 'luassert'
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
local Message = require("aviary.shared.message")
local Process = require("aviary.shared.process")

describe("pigeon tmux backend", function()
  local Backend, Config, Cli, socket_dir, saved_tmux, saved_pane, saved_tmux_tmpdir, saved_cwd
  local function tmux(...)
    return Process.run({ "tmux", ... }, { text = false })
  end
  local function query(...)
    local result = tmux(...)
    assert.are.equal(0, result.code, result.stderr)
    return vim.trim(result.stdout)
  end
  local function create(name, command)
    assert(Config.setup({ tools = { [name or "test"] = { command = command or { "sh" } } } }))
    return Helpers.create(Backend, name or "test")
  end
  before_each(function()
    Helpers.reload_pigeon()
    Backend = require("aviary.pigeon.backends.tmux")
    Config = require("aviary.pigeon.config")
    Cli = require("aviary.pigeon.backends.tmux.cli")
    saved_tmux, saved_pane = vim.env.TMUX, vim.env.TMUX_PANE
    saved_tmux_tmpdir, saved_cwd = vim.env.TMUX_TMPDIR, vim.fn.getcwd()
    socket_dir = vim.fn.tempname()
    vim.fn.mkdir(socket_dir, "p")
    vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
    vim.env.TMUX_TMPDIR = socket_dir
    local result = Process.run({
      "tmux",
      "-f",
      "/dev/null",
      "new-session",
      "-d",
      "-s",
      "host",
      "-P",
      "-F",
      "#{socket_path}",
      "sleep",
      "300",
    })
    assert.are.equal(0, result.code, result.stderr)
    vim.env.TMUX, vim.env.TMUX_PANE = vim.trim(result.stdout) .. ",0,0", nil
    assert.are.equal(0, tmux("set-option", "-g", "-w", "remain-on-exit", "on").code)
    assert.are.equal(0, tmux("set-option", "-g", "-w", "pane-border-status", "top").code)
  end)
  after_each(function()
    tmux("kill-server")
    vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TMUX_TMPDIR = saved_tmux, saved_pane, saved_tmux_tmpdir
    vim.fn.delete(socket_dir, "rf")
    vim.api.nvim_set_current_dir(saved_cwd)
    Helpers.reload_pigeon()
  end)

  it("creates one persistent session/window per Agent with direct-display options", function()
    local first, second = create(), create()
    assert.are_not.equal(first.session, second.session)
    assert.are_not.equal(first.pane, second.pane)
    assert.are.equal(first.session, first:id())
    assert.are.equal("test", first.tool)
    assert.are.equal("1", query("display", "-p", "-t", "=" .. first.session .. ":", "#{session_windows}"))
    assert.are.equal("off", query("show-options", "-v", "-t", "=" .. first.session .. ":", "destroy-unattached"))
    assert.are.equal("on", query("show-options", "-v", "-t", "=" .. first.session .. ":", "detach-on-destroy"))
    assert.are.equal("off", query("show-options", "-v", "-t", "=" .. first.session .. ":", "status"))
    assert.are.equal("None", query("show-options", "-v", "-t", "=" .. first.session .. ":", "prefix"))
    assert.are.equal("None", query("show-options", "-v", "-t", "=" .. first.session .. ":", "prefix2"))
    assert.are.equal("off", query("show-options", "-w", "-v", "-t", "=" .. first.session .. ":", "remain-on-exit"))
    assert.are.equal("off", query("show-options", "-w", "-v", "-t", "=" .. first.session .. ":", "pane-border-status"))
    assert.are.equal(
      first.session,
      query("show-options", "-w", "-v", "-t", "=" .. first.session .. ":", "@pigeon_session")
    )
    assert.are.equal("test", query("show-options", "-w", "-v", "-t", "=" .. first.session .. ":", "@pigeon_tool"))
    query("rename-window", "-t", "host:", "test")
    assert.are.equal(2, #Helpers.agents(Backend))
    assert.are.equal("test", query("display", "-p", "-t", "host:", "#{window_name}"))
    query("rename-window", "-t", "=" .. first.session .. ":", "codex")
    assert.are.equal("test", Helpers.agents(Backend)[1].tool)
    local sessions = vim.split(query("list-sessions", "-F", "#{session_name}"), "\n", { plain = true })
    assert.are.equal(3, #sessions)
  end)

  it("uses tool and session ids independently of display strings", function()
    local first = create()
    local choices = Backend.list()
    assert.are.equal(first.session, first:id())
    local tool_choice
    for _, choice in ipairs(choices) do
      if choice.tool then
        tool_choice = choice
      end
    end
    assert.are.equal("test", assert(tool_choice):id())
    assert.is_truthy(tostring(first):find(first.session, 1, true))
  end)

  it("preserves literal Unicode, separators, format syntax and trailing semicolons in discovery", function()
    local directory = vim.fn.tempname() .. " 路径\tline\r\n#{session_name};"
    vim.fn.mkdir(directory, "p")
    vim.api.nvim_set_current_dir(directory)
    local name = "tool#{session_name};"
    local agent = create(name)
    assert.are.same(agent, Helpers.agents(Backend)[1])
    assert.are.equal(directory, agent.cwd)
    assert.are.equal(name, Helpers.agents(Backend)[1].tool)
    vim.api.nvim_set_current_dir(saved_cwd)
    vim.fn.delete(directory, "rf")
  end)

  it("passes command argv literally without shell or tmux command injection", function()
    local path = vim.fn.tempname()
    local args = { "a b", "$(touch /should-not-run)", "#{session_name}", "x;", ";" }
    local command = {
      "python3",
      "-c",
      "import json,sys,time; open(sys.argv[1],'w').write(json.dumps(sys.argv[2:])); time.sleep(300)",
      path,
    }
    vim.list_extend(command, args)
    create("test", command)
    assert(vim.wait(2000, function()
      return vim.fn.filereadable(path) == 1
    end))
    assert.are.same(args, vim.json.decode(table.concat(vim.fn.readfile(path), "\n")))
    vim.fn.delete(path)
  end)

  it("deduplicates shared windows and filters tools absent from local configuration", function()
    local first, second = create(), create()
    query("new-session", "-d", "-s", "view", "-t", "=" .. first.session)
    assert.are.equal(2, #Cli.list())
    assert.are.equal(2, #Helpers.agents(Backend))
    query("set-option", "-w", "-t", "=" .. second.session .. ":", "@pigeon_tool", "not-configured")
    assert.are.equal(1, #Helpers.agents(Backend))
  end)

  it("uses exact session targets for attach and retarget", function()
    local saved = Process.run
    local calls = {}
    Process.run = function(argv, opts)
      calls[#calls + 1] = { argv = vim.deepcopy(argv), opts = opts }
      return { code = 0, signal = 0, stdout = "", stderr = "" }
    end
    local ok, err = pcall(function()
      assert.are.same({ "env", "-u", "TMUX", "tmux", "attach-session", "-t", "=session" }, Cli.attach("session"))
      Cli.retarget("client", "session")
      assert.are.same({ "tmux", "switch-client", "-c", "client", "-t", "=session" }, calls[#calls].argv)
    end)
    Process.run = saved
    assert(ok, err)
  end)

  it("uses current local formats and evaluates fully before any delivery", function()
    local agent = create()
    assert(Config.setup({
      tools = {
        test = {
          command = { "sh" },
          format = function(path)
            return "!" .. path
          end,
        },
      },
    }))
    assert.are.equal("!a.lua", agent:eval(Message.reference(agent.cwd .. "/a.lua")))
    local text = "HIDDEN_TEXT"
    agent:send(agent:eval(Message.text(text)))
    assert(vim.wait(2000, function()
      return query("capture-pane", "-p", "-t", agent.pane):find(text, 1, true) ~= nil
    end))
    agent:send("")
    Config.setup()
    assert.has_error(function()
      agent:eval(Message.text("text"))
    end)
  end)
end)
