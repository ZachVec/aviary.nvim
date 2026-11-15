---@module 'luassert'
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
local Message = require("aviary.shared.message")
local Process = require("aviary.shared.process")

describe("pigeon managed tmux targets", function()
  local backend, Config, socket
  local generation = 0
  local saved_tmux, saved_pane, saved_select, saved_cwd

  local function configure(opts)
    assert(Config.setup(opts))
  end
  local function receiver(target)
    return "=" .. target.instance .. ":"
  end
  local function tmux(...)
    return Process.run({ "tmux", ... })
  end
  local function start()
    configure()
    local result = Process.run({
      "tmux",
      "-L",
      socket,
      "-f",
      "/dev/null",
      "new-session",
      "-d",
      "-s",
      "editor",
      "-x",
      "120",
      "-y",
      "40",
      "-P",
      "-F",
      "#{socket_path}",
      "sleep",
      "300",
    })
    assert.are.equal(0, result.code, result.stderr)
    vim.env.TMUX, vim.env.TMUX_PANE = vim.trim(result.stdout) .. ",0,0", "%0"
  end
  local function list()
    return Helpers.targets(backend)
  end
  local function send(target, message)
    return target:send(target:eval(message))
  end
  local function show(target)
    return target:show()
  end
  local function create(command)
    configure({
      tools = {
        receiver = {
          command = command or { "sh" },
          format = function(path, row)
            return "!" .. path .. (row and ":" .. row or "")
          end,
        },
      },
    })
    return Helpers.create(backend, "receiver")
  end

  before_each(function()
    assert.are.equal(1, vim.fn.executable("tmux"), "tmux is required for integration specs")
    Helpers.reload_pigeon()
    Config = require("aviary.pigeon.config")
    backend = require("aviary.pigeon.backends.tmux")
    saved_tmux, saved_pane, saved_select, saved_cwd = vim.env.TMUX, vim.env.TMUX_PANE, vim.ui.select, vim.fn.getcwd()
    generation = generation + 1
    socket = ("aviary-pigeon-test-%d-%d"):format(vim.fn.getpid(), generation)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function()
      error("backend creation must not open a picker")
    end
    start()
  end)
  after_each(function()
    tmux("kill-server")
    vim.env.TMUX, vim.env.TMUX_PANE, vim.ui.select = saved_tmux, saved_pane, saved_select
    vim.api.nvim_set_current_dir(saved_cwd)
    Helpers.reload_pigeon()
  end)

  it("discovers literal tool names and directories from receiver fields", function()
    local dir = vim.fn.tempname() .. " 路径\tline\r\nnext"
    vim.fn.mkdir(dir, "p")
    vim.api.nvim_set_current_dir(dir)
    local name = "tool#{session_name};"
    configure({ tools = { [name] = { command = { "sh" } } } })
    local target = Helpers.create(backend, name)
    local listed = list()
    assert.are.equal(1, #listed)
    assert.are.same({ instance = target.instance, tool = name, cwd = dir }, listed[1])
    assert.is_true(target == listed[1])
    assert.is_false(rawequal(target, listed[1]))
    vim.api.nvim_set_current_dir(saved_cwd)
    vim.fn.delete(dir, "rf")
  end)

  it("excludes user sessions even when their window names match configured tools", function()
    local target = create()
    assert.are.equal(0, tmux("rename-window", "-t", "editor:", "receiver").code)
    assert.are.equal(0, tmux("new-session", "-d", "-s", "user", "-n", "codex", "sleep", "300").code)
    assert.are.equal(0, tmux("set-option", "-t", "user:", "@pigeon_tool", "").code)
    local listed = list()
    assert.are.equal(1, #listed)
    assert.is_true(target == listed[1])
    assert.are.equal("receiver", vim.trim(tmux("display-message", "-p", "-t", "editor:", "#{window_name}").stdout))
    assert.are.equal("codex", vim.trim(tmux("display-message", "-p", "-t", "user:", "#{window_name}").stdout))
  end)

  it("discovers a receiver whose tool name is zero", function()
    configure({ tools = { ["0"] = { command = { "sh" } } } })
    local target = Helpers.create(backend, "0")
    local listed = list()
    assert.are.equal(1, #listed)
    assert.are.same({ instance = target.instance, tool = "0", cwd = target.cwd }, listed[1])
  end)

  it("keeps tool identity when the receiver window is renamed to another configured tool", function()
    local target = create()
    assert.are.equal(0, tmux("rename-window", "-t", receiver(target), "codex").code)
    local listed = list()
    assert.are.equal(1, #listed)
    assert.are.same({ instance = target.instance, tool = "receiver", cwd = target.cwd }, listed[1])
    assert.is_true(target == listed[1])
    assert.is_nil(send(listed[1], Message.text("renamed receiver")))
  end)

  it("discovers managed targets without a source pane and never probes processes", function()
    local target = create()
    vim.env.TMUX_PANE = nil
    local saved_run = Process.run
    ---@diagnostic disable-next-line: duplicate-set-field
    Process.run = function(command, opts)
      assert.are_not.equal("ps", command[1])
      return saved_run(command, opts)
    end
    local ok, reason = pcall(function()
      assert.is_true(target == list()[1])
      send(target, Message.text("draft"))
    end)
    Process.run = saved_run
    assert(ok, reason)
  end)

  it("uses the inherited server for discovery, creation and sending", function()
    tmux("kill-server")
    socket = socket .. "-changed"
    start()
    local target = create()
    assert.are.equal(1, #list())
    assert.are.equal(0, tmux("has-session", "-t", "=" .. target.instance).code)
    send(target, Message.text("AVIARY_INHERITED_SERVER"))
    assert(vim.wait(2000, function()
      return tmux("capture-pane", "-p", "-t", receiver(target)).stdout:find("AVIARY_INHERITED_SERVER", 1, true) ~= nil
    end, 20))
  end)

  it("keeps multiple instances of one tool distinct and preserves the source window", function()
    local before = tmux(
      "display-message",
      "-p",
      "-t",
      "%0",
      "#{session_id}|#{window_id}|#{window_layout}|#{window_zoomed_flag}"
    ).stdout
    local first, second = create(), create()
    assert.is_false(first == second)
    assert.are_not.equal(tostring(first), tostring(second))
    assert.are.equal(2, #list())
    assert.are.equal(
      before,
      tmux("display-message", "-p", "-t", "%0", "#{session_id}|#{window_id}|#{window_layout}|#{window_zoomed_flag}").stdout
    )
    assert.are.equal("off", vim.trim(tmux("show-options", "-v", "-t", receiver(first), "status").stdout))
  end)

  it("inherits host options while overriding receiver input and lifetime options", function()
    local inherited = {
      status = "on",
      prefix = "C-a",
      prefix2 = "C-b",
      ["detach-on-destroy"] = "off",
      ["history-limit"] = "4321",
      mouse = "on",
    }
    for key, value in pairs(inherited) do
      assert.are.equal(0, tmux("set-option", "-g", key, value).code)
    end
    for _, key in ipairs({ "remain-on-exit", "allow-rename" }) do
      assert.are.equal(0, tmux("set-option", "-g", "-w", key, "on").code)
    end
    local target = create({ "cat" })
    for key, value in pairs({
      status = "off",
      prefix = "None",
      prefix2 = "None",
      ["destroy-unattached"] = "off",
      ["detach-on-destroy"] = "on",
      ["@pigeon_tool"] = "receiver",
      ["history-limit"] = "4321",
      mouse = "on",
    }) do
      assert.are.equal(value, vim.trim(tmux("show-options", "-A", "-v", "-t", receiver(target), key).stdout), key)
    end
    for key, value in pairs(inherited) do
      assert.are.equal(value, vim.trim(tmux("show-options", "-A", "-v", "-t", "editor:", key).stdout), key)
    end
    assert.are.equal("off", vim.trim(tmux("show-options", "-w", "-v", "-t", receiver(target), "remain-on-exit").stdout))
    assert.are.equal(
      "on",
      vim.trim(tmux("show-options", "-A", "-w", "-v", "-t", receiver(target), "allow-rename").stdout)
    )
    assert.are.equal("on", vim.trim(tmux("show-options", "-A", "-w", "-v", "-t", "editor:", "remain-on-exit").stdout))
    assert.are.equal(0, tmux("set-option", "-t", "editor:", "destroy-unattached", "off").code)
    assert.are.equal(0, tmux("set-option", "-g", "destroy-unattached", "on").code)
    assert.are.equal(0, tmux("has-session", "-t", "=" .. target.instance).code)
    tmux("send-keys", "-t", receiver(target), "C-d")
    assert(vim.wait(2000, function()
      return tmux("has-session", "-t", "=" .. target.instance).code ~= 0
    end, 20))
    assert.are.same({}, list())
  end)

  it("keeps the receiver alive after its user source session closes", function()
    local target = create({ "cat" })
    assert.is_nil(show(target))
    assert.are.equal(0, tmux("kill-session", "-t", "=editor").code)
    assert.are.equal(0, tmux("has-session", "-t", "=" .. target.instance).code)
    local listed = list()
    assert.are.equal(1, #listed)
    assert.is_true(target == listed[1])
    assert.is_nil(send(target, Message.text("AVIARY_SOURCE_CLOSED")))
    assert(vim.wait(2000, function()
      return tmux("capture-pane", "-p", "-t", receiver(target)).stdout:find("AVIARY_SOURCE_CLOSED", 1, true) ~= nil
    end, 20))
  end)

  it("uses a shared receiver key table and preserves root bindings on valid and invalid close keys", function()
    assert.are.equal(0, tmux("bind-key", "-T", "root", "C-.", "display-message", "user binding").code)
    local root = tmux("list-keys", "-T", "root").stdout
    local source_table = tmux("show-options", "-A", "-v", "-t", "editor:", "key-table").stdout
    local target = create()
    assert.is_nil(show(target))
    assert.are.equal("C-.", vim.trim(tmux("list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}").stdout))
    assert.are.equal("aviary-pigeon", vim.trim(tmux("show-options", "-v", "-t", receiver(target), "key-table").stdout))
    assert.are.equal(root, tmux("list-keys", "-T", "root").stdout)
    configure({ backend = { tmux = { close = "not-a-tmux-key" } } })
    local ok, why = pcall(show, target)
    assert.is_false(ok)
    assert.is_string(why)
    assert.is_truthy(why:find("unknown key", 1, true))
    assert.are.equal("C-.", vim.trim(tmux("list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}").stdout))
    assert.are.equal(root, tmux("list-keys", "-T", "root").stdout)
    assert.are.equal(source_table, tmux("show-options", "-A", "-v", "-t", "editor:", "key-table").stdout)
    assert.are.equal(2, #vim.split(vim.trim(tmux("list-panes", "-t", "editor", "-F", "#{pane_id}").stdout), "\n"))
    assert.are.equal("%0", vim.trim(tmux("display-message", "-p", "-t", "%2", "#{@pigeon_source}").stdout))
  end)

  it("shares the latest close key across receivers and restores their key table on every focus", function()
    local first, second = create(), create()
    assert.is_nil(show(first))
    assert.is_nil(show(second))
    configure({ backend = { tmux = { close = "F11" } } })
    assert.are.equal(0, tmux("set-option", "-t", receiver(first), "key-table", "root").code)
    assert.is_nil(show(first))
    assert.are.equal("F11", vim.trim(tmux("list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}").stdout))
    for _, target in ipairs({ first, second }) do
      assert.are.equal(
        "aviary-pigeon",
        vim.trim(tmux("show-options", "-v", "-t", receiver(target), "key-table").stdout)
      )
    end
  end)

  it("discovers instance and launch cwd from native fields and tool from its session option", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.api.nvim_set_current_dir(dir)
    configure({
      tools = {
        receiver = {
          command = { "sh" },
          format = function(path)
            return path
          end,
        },
      },
    })
    local target = Helpers.create(backend, "receiver")
    vim.api.nvim_set_current_dir("/tmp")
    configure({ tools = { receiver = { command = { "sleep", "30" } } } })
    assert.are.equal(dir, target.cwd)
    assert.are.same({ instance = target.instance, tool = "receiver", cwd = dir }, target)
    assert.are.equal(
      "receiver",
      vim.trim(tmux("display-message", "-p", "-t", receiver(target), "#{window_name}").stdout)
    )
    assert.are.equal(dir, vim.trim(tmux("display-message", "-p", "-t", receiver(target), "#{pane_start_path}").stdout))
    assert.are.equal("receiver", vim.trim(tmux("show-options", "-v", "-t", receiver(target), "@pigeon_tool").stdout))
    assert.are.equal(
      "off",
      vim.trim(tmux("show-options", "-w", "-v", "-t", receiver(target), "automatic-rename").stdout)
    )
    assert.are.equal(
      target.instance,
      vim.trim(tmux("display-message", "-p", "-t", receiver(target), "#{session_name}").stdout)
    )
    tmux("send-keys", "-t", receiver(target), "cd /", "Enter")
    assert(vim.wait(2000, function()
      return vim.trim(tmux("display-message", "-p", "-t", receiver(target), "#{pane_current_path}").stdout) == "/"
    end, 20))
    assert.are.equal(dir, list()[1].cwd)
    vim.fn.delete(dir, "rf")
  end)

  it("binds semicolon close keys prepared by setup", function()
    local target = create()
    for _, key in ipairs({ ";", "M-;" }) do
      configure({ backend = { tmux = { close = key } } })
      assert.is_nil(show(target))
      assert.are.equal(key, Config().backend.tmux.close)
      assert.are.equal(key, vim.trim(tmux("list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}").stdout))
    end
  end)

  it("preserves literal tmux format characters and separators in cwd", function()
    local dir = vim.fn.tempname() .. " #{session_name};"
    vim.fn.mkdir(dir, "p")
    vim.api.nvim_set_current_dir(dir)
    local ok, reason = pcall(function()
      local target = create()
      local actual = tmux("display-message", "-p", "-t", receiver(target), "#{pane_current_path}")
      assert.are.equal(dir, vim.trim(actual.stdout))
    end)
    vim.api.nvim_set_current_dir(saved_cwd)
    vim.fn.delete(dir, "rf")
    assert(ok, reason)
  end)

  it("rejects a tool definition removed after discovery before acquiring resources", function()
    configure({ tools = { removed = { command = { "sh" } } } })
    local pending
    for _, item in ipairs(backend.list()) do
      if tostring(item) == " removed" then
        pending = item
      end
    end
    configure()
    local ok, reason = pcall(function()
      return pending:resolve()
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(reason):find("missing local tool definition: removed", 1, true))
    assert.are.same({}, list())
    assert.are.equal("editor", vim.trim(tmux("list-sessions", "-F", "#{session_name}").stdout))
  end)

  it("rolls back the session when a later initialization command fails", function()
    local run = Process.run
    ---@diagnostic disable-next-line: duplicate-set-field
    Process.run = function(args, opts)
      if args[2] == "set-option" then
        args = vim.deepcopy(args)
        args[#args - 1] = "invalid-aviary-option"
      end
      return run(args, opts)
    end
    local ok, why = pcall(create)
    Process.run = run
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("invalid", 1, true))
    assert.are.equal("editor", vim.trim(tmux("list-sessions", "-F", "#{session_name}").stdout))
  end)

  it("passes exact argv, including whitespace and command separators, without a shell", function()
    local target = create({
      "python3",
      "-c",
      "import json,sys,time; print(json.dumps(sys.argv[1:]),flush=True); time.sleep(30)",
      "a b",
      ";",
      "$(echo bad);",
      "quote'\"",
      "#{session_name}",
      "slash\\;",
    })
    assert(vim.wait(2000, function()
      return tmux("capture-pane", "-p", "-t", receiver(target)).stdout:find('"a b", ";", "$(echo bad);"', 1, true)
        ~= nil
    end, 20))
    local output = tmux("capture-pane", "-p", "-t", receiver(target)).stdout
    assert.is_truthy(output:find("#{session_name}", 1, true))
    assert.is_truthy(output:find("slash\\\\;", 1, true))
  end)

  it("uses captured cwd and the latest local format even after rediscovery", function()
    local target = create()
    local observed
    local message = {
      eval = function(_, ctx)
        observed = ctx
        return "hello"
      end,
    }
    send(target, message)
    assert.are.equal(target.cwd, observed.cwd)
    local format = function(path, start_row, end_row)
      return table.concat({ path, start_row, end_row }, ":")
    end
    configure({ tools = { receiver = { command = { "sleep", "30" }, format = format } } })
    local fresh = list()[1]
    send(target, message)
    assert.are.equal(format, observed.format)
    send(fresh, message)
    assert.are.equal(format, observed.format)
  end)

  it("uses the current default for tools without a format override", function()
    configure({ tools = { codex = { command = { "sh" } } } })
    local target = Helpers.create(backend, "codex")
    local seen
    local message = {
      eval = function(_, ctx)
        seen = ctx
        return "draft"
      end,
    }
    send(target, message)
    assert.are.equal(Config().format, seen.format)
    local format = function(path)
      return "!" .. path
    end
    configure({ format = format, tools = { codex = { command = { "sleep", "30" } } } })
    send(list()[1], message)
    assert.are.equal(format, seen.format)
  end)

  it("skips targets without local tool definitions and preserves their running resources", function()
    local target = create()
    configure()
    local listed = list()
    assert.are.same({}, listed)
    local sent, failure = pcall(function()
      send(target, Message.text("hello"))
    end)
    assert.is_false(sent)
    assert.is_truthy(tostring(failure):find("missing local tool definition: receiver", 1, true))
    assert.are.equal(0, tmux("has-session", "-t", ("=" .. target.instance)).code)

    configure({ tools = { receiver = { command = { "sh" } } } })
    listed = list()
    assert.are.equal(1, #listed)
    assert.is_true(target == listed[1])
  end)

  it("lists only live targets whose tools are configured locally", function()
    local first, second = create(), create()
    configure({ tools = { other = { command = { "sh" } }, codex = { command = { "sh" } } } })
    local other = Helpers.create(backend, "other")
    local known = Helpers.create(backend, "codex")
    configure()
    local listed = list()
    assert.are.equal(1, #listed)
    assert.is_true(known == listed[1])
    for _, target in ipairs({ first, second, other }) do
      assert.are.equal(0, tmux("has-session", "-t", "=" .. target.instance).code)
    end
  end)

  it("can pick and send to configured targets when another live tool is missing locally", function()
    local unknown = create()
    configure({
      tools = { codex = { command = { "sh" } } },
      backend = { default = "tmux" },
    })
    local known = Helpers.create(backend, "codex")
    local choices, confirm
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, confirm = items, done
    end
    local pigeon = require("aviary").pigeon
    local notes = Helpers.notifications(function()
      pigeon.send(Message.text("AVIARY_DISCOVERY_DRAFT"))
      assert.is_not_nil(choices)
    end)
    assert.are.same({}, notes)
    assert.are.equal(3, #choices)
    assert.is_true(known == choices[1])
    assert.are.same({ " claude", " codex" }, { tostring(choices[2]), tostring(choices[3]) })
    assert.are.same(
      {},
      Helpers.notifications(function()
        confirm(choices[1])
      end)
    )
    assert(vim.wait(2000, function()
      return tmux("capture-pane", "-p", "-t", receiver(known)).stdout:find("AVIARY_DISCOVERY_DRAFT", 1, true) ~= nil
    end, 20))
    assert.are.equal(0, tmux("has-session", "-t", ("=" .. unknown.instance)).code)
  end)

  it("sends no partial content or staging buffer when evaluation fails", function()
    local target = create()
    local ok, err = pcall(function()
      send(target, {
        eval = function()
          return nil, "declined reference"
        end,
      })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("declined reference", 1, true))
    assert.are.equal("", vim.trim(tmux("list-buffers").stdout))
    assert.are.equal("", vim.trim(tmux("capture-pane", "-p", "-t", receiver(target)).stdout):gsub("[%$#]", ""))
  end)

  it("retains its fixed staging buffer after a missing destination and overwrites it next time", function()
    local target = create()
    tmux("set-buffer", "-b", "borrowed", "keep me")
    assert.has_error(function()
      send(target, {
        eval = function()
          tmux("kill-session", "-t", "=" .. target.instance)
          return "hello"
        end,
      })
    end)
    local owned = "aviary-pigeon-" .. vim.fn.getpid()
    local names = vim.split(vim.trim(tmux("list-buffers", "-F", "#{buffer_name}").stdout), "\n")
    table.sort(names)
    assert.are.same({ owned, "borrowed" }, names)
    assert.are.equal("hello", tmux("show-buffer", "-b", owned).stdout)
    local replacement = create()
    assert.is_nil(send(replacement, Message.text("replacement text")))
    assert.are.equal("borrowed", vim.trim(tmux("list-buffers", "-F", "#{buffer_name}").stdout))
    assert.are.equal("keep me", tmux("show-buffer", "-b", "borrowed").stdout)
  end)

  it("sends multiline drafts verbatim without submitting, focusing or resizing the editor", function()
    local target = create()
    send(target, Message.text("echo AVIARY_SEND_MARKER\nsecond line"))
    assert(vim.wait(2000, function()
      return tmux("capture-pane", "-p", "-t", receiver(target)).stdout:find("second line", 1, true) ~= nil
    end, 20))
    local output = tmux("capture-pane", "-p", "-t", receiver(target)).stdout
    for line in output:gmatch("[^\r\n]+") do
      assert.are_not.equal("AVIARY_SEND_MARKER", vim.trim(line))
    end
    assert.are.equal("", vim.trim(tmux("list-buffers").stdout))
    assert.are.equal("%0", vim.trim(tmux("display-message", "-p", "-t", "editor:", "#{pane_id}").stdout))
  end)

  it("automatically removes its pane and session when the process exits", function()
    local target = create({ "cat" })
    assert.are.equal("off", vim.trim(tmux("show-options", "-w", "-v", "-t", receiver(target), "remain-on-exit").stdout))
    tmux("send-keys", "-t", receiver(target), "C-d")
    assert(vim.wait(2000, function()
      return tmux("has-session", "-t", "=" .. target.instance).code ~= 0
    end, 20))
    assert.are.same({}, list())
    assert.has_error(function()
      send(target, Message.text("no restart"))
    end)
    assert.has_error(function()
      show(target)
    end)
  end)

  it("does not redirect stale instances after the host server restarts", function()
    local old = create()
    tmux("kill-server")
    start()
    local replacement = create()
    assert.is_false(old == replacement)
    assert.has_error(function()
      send(old, Message.text("wrong instance"))
    end)
    assert.is_nil(send(replacement, Message.text("correct instance")))
  end)

  it("creates, discovers and sends without executable or version preflights", function()
    local saved, executable = Process.run, vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function()
      error("unexpected executable preflight")
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    Process.run = function(args, opts)
      assert.is_false(vim.tbl_contains(args, "-V"))
      assert.is_false(vim.tbl_contains(args, "#{version}"))
      return saved(args, opts)
    end
    local ok, why = pcall(function()
      local target = create()
      assert.are.equal(1, #list())
      assert.is_nil(send(target, Message.text("draft")))
    end)
    Process.run, vim.fn.executable = saved, executable
    assert(ok, why)
  end)
end)
