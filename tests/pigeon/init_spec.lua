---@module 'luassert'
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
local Message = require("aviary.shared.message")

describe("aviary.pigeon", function()
  local Pigeon
  local saved_has, saved_setreg, saved_getreg, saved_notify, saved_select
  local clipboard, writes, notes, available
  local targets, listing_error, listing_calls, created, creation_error, create_calls, created_names
  local items, choice, picker_opts, offer_tools

  local function equal(a, b)
    return a.name == b.name
  end

  local function target(name)
    local self = { name = name, sent = {}, shown = 0, evaluated = {} }
    function self:resolve()
      return self
    end
    function self:eval(message)
      self.evaluated[#self.evaluated + 1] = message
      if self.eval_failure then
        error(self.eval_failure, 0)
      end
      return assert(message:eval({
        format = function(path)
          return path
        end,
      }))
    end
    function self:send(text)
      if self.missing then
        error("target gone", 0)
      end
      if self.failure then
        error(self.failure, 0)
      end
      self.sent[#self.sent + 1] = text
    end
    function self:show()
      if self.missing then
        error("target gone", 0)
      end
      self.shown = self.shown + 1
      if self.failure then
        error(self.failure, 0)
      end
    end
    return setmetatable(self, {
      __eq = equal,
      __tostring = function()
        return " " .. name
      end,
    })
  end

  local function send(message)
    Pigeon.send(message or Message.text("hello"))
  end

  local function item(kind, key)
    for _, candidate in ipairs(items) do
      if tostring(candidate) == (kind == "target" and " " or " ") .. key then
        return candidate
      end
    end
    error("missing " .. kind .. " choice: " .. key)
  end

  local function choose_target(id)
    choice(item("target", id))
  end

  local function choose_tool(name)
    choice(item("tool", name))
  end

  before_each(function()
    Helpers.reload_pigeon()
    saved_has, saved_setreg, saved_getreg = vim.fn.has, vim.fn.setreg, vim.fn.getreg
    saved_notify, saved_select = vim.notify, vim.ui.select
    clipboard, writes, notes, available = "", {}, {}, true
    targets, listing_error, listing_calls, create_calls = {}, nil, 0, 0
    items, choice, picker_opts, offer_tools = nil, nil, nil, true
    created, creation_error, created_names = target("new"), nil, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.has = function(name)
      if name == "clipboard" then
        return available and 1 or 0
      end
      return saved_has(name)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function(register, text, kind)
      assert.are.equal("+", register)
      assert.are.equal("v", kind)
      writes[#writes + 1] = text
      return 0
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.getreg = function(register)
      assert.are.equal("+", register)
      return clipboard
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(text)
      notes[#notes + 1] = text
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(candidates, opts, done)
      items, picker_opts, choice = candidates, opts, done
    end
    package.loaded["aviary.pigeon.backends.tmux"] = {
      list = function()
        listing_calls = listing_calls + 1
        if listing_error then
          error(listing_error, 0)
        end
        local choices = vim.list_slice(targets)
        if offer_tools then
          local tools = vim.tbl_keys(require("aviary.pigeon.config")().tools)
          table.sort(tools)
          for _, name in ipairs(tools) do
            choices[#choices + 1] = setmetatable({
              resolve = function()
                create_calls = create_calls + 1
                created_names[#created_names + 1] = name
                if creation_error then
                  error(creation_error, 0)
                end
                return created
              end,
            }, {
              __tostring = function()
                return " " .. name
              end,
            })
          end
        end
        return choices
      end,
    }
    Pigeon = require("aviary").pigeon
  end)

  after_each(function()
    vim.fn.has, vim.fn.setreg, vim.fn.getreg = saved_has, saved_setreg, saved_getreg
    vim.notify, vim.ui.select = saved_notify, saved_select
    Helpers.reload_pigeon()
  end)

  it("defaults to clipboard, renders generic references and reuses the receiver", function()
    send(Message.reference("/tmp/a.lua", 2))
    assert.are.same({ "/tmp/a.lua :L2" }, writes)
    assert.is_nil(items)
    send(Message.text(""))
    assert.are.same({ "/tmp/a.lua :L2", "" }, writes)
    assert.are.equal(0, listing_calls)
  end)

  it("uses the current configured default format on an already selected clipboard", function()
    local message = Message.reference("/tmp/a.lua", 2, 5)
    send(message)
    local seen
    Pigeon.setup({
      format = function(...)
        seen = { ... }
        return "custom reference"
      end,
    })
    send(message)
    assert.are.same({ "/tmp/a.lua", 2, 5 }, seen)
    assert.are.same({ "/tmp/a.lua :L2-5", "custom reference" }, writes)
    send(Message.text("literal"))
    assert.are.equal("literal", writes[3])
  end)

  it("does not copy partial content when the configured default formatter fails", function()
    local message = Message.join(" ", { Message.text("prefix"), Message.reference("/tmp/a.lua") })
    for _, format in ipairs({
      function() end,
      function()
        return ""
      end,
      function()
        error("bad format")
      end,
    }) do
      Pigeon.setup({ format = format })
      send(message)
    end
    assert.are.same({}, writes)
    assert.are.equal(3, #notes)
  end)

  it("clears the selected clipboard when evaluation fails and selects on the next action", function()
    send()
    Pigeon.setup({
      backend = { default = "tmux" },
      format = function() end,
    })
    send(Message.reference("/tmp/a.lua"))
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("reference could not be formatted", 1, true))
    send(Message.text("next draft"))
    assert.are.same({ "hello" }, writes)
    assert.are.equal(1, listing_calls)
    choose_tool("codex")
    assert.are.same({ "next draft" }, created.sent)
  end)

  it("shows multiline and empty clipboard content without writing", function()
    clipboard = "line one\nline two"
    Pigeon.show()
    clipboard = ""
    Pigeon.show()
    assert.are.same({ "line one\nline two", "pigeon: clipboard is empty" }, notes)
    assert.are.same({}, writes)
    assert.are.equal(0, listing_calls)
  end)

  for _, action in ipairs({ "pick", "send", "show" }) do
    it("automatically selects clipboard without offering tools through " .. action, function()
      clipboard = "selected clipboard"
      Pigeon.setup({ tools = { receiver = { command = { "sh" } } } })
      if action == "send" then
        send()
      else
        Pigeon[action]()
      end
      assert.is_nil(items)
      assert.are.same(action == "send" and {} or { "selected clipboard" }, notes)
      assert.are.same(action == "send" and { "hello" } or {}, writes)
      assert.are.equal(0, listing_calls)
      assert.are.equal(0, create_calls)
    end)

    it("leaves clipboard provider diagnostics to health through " .. action, function()
      available = false
      if action == "send" then
        send()
      else
        Pigeon[action]()
      end
      assert.is_nil(items)
      assert.are.same(action == "send" and {} or { "pigeon: clipboard is empty" }, notes)
      assert.are.same(action == "send" and { "hello" } or {}, writes)
      assert.are.equal(0, create_calls)
    end)
  end

  it("uses the backend inventory without inferring creation capabilities", function()
    targets = { target("a"), target("b") }
    offer_tools = false
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    assert.are.equal(2, #items)
    assert.are.same({ targets[1], targets[2] }, items)
    choose_target("a")
    assert.are.equal(1, targets[1].shown)
    assert.are.same({}, notes)
  end)

  it("shows an existing target after confirming it alongside all configured tools", function()
    targets = { target("a") }
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    assert.are.equal(3, #items)
    assert.are.equal(" claude", picker_opts.format_item(item("tool", "claude")))
    assert.are.equal(" codex", picker_opts.format_item(item("tool", "codex")))
    assert.are.equal(" a", picker_opts.format_item(item("target", "a")))
    assert.are.equal(0, targets[1].shown)
    choose_target("a")
    assert.are.equal(1, targets[1].shown)
    assert.are.same({}, targets[1].sent)
    assert.is_nil(package.loaded["aviary.pigeon.backends.clipboard"])
    send()
    assert.are.equal(1, #targets[1].sent)
    assert.are.same({}, writes)
  end)

  it("waits for a default target choice for show and then reuses it for send", function()
    local only = target("a")
    targets = { only }
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.show()
    assert.are.equal(0, only.shown)
    choose_target("a")
    assert.are.equal(1, only.shown)
    local message = Message.text("test")
    send(message)
    assert.are.equal("test", only.sent[1])
    assert.are.equal(message, only.evaluated[1])
    assert.are.equal(1, listing_calls)
  end)

  it("delays delivery until one of multiple targets is chosen", function()
    targets = { target("a"), target("b") }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    assert.are.equal(0, #targets[1].sent + #targets[2].sent)
    choice(items[2])
    assert.are.equal(1, #targets[2].sent)
    assert.are.equal(0, #targets[1].sent)
    assert.are.equal(0, targets[2].shown)
  end)

  it("reports deferred send exceptions once and clears current for the next action", function()
    targets = { target("a"), target("b") }
    targets[2].failure = "send failed"
    Pigeon.setup({ backend = { default = "tmux" } })
    local message = Message.text("deferred")
    send(message)
    choice(items[2])
    assert.are.same({ "send failed" }, notes)
    targets[2].failure = nil
    send(message)
    choice(item("target", "b"))
    assert.are.same({ "deferred" }, targets[2].sent)
    assert.are.same({}, targets[1].sent)
    assert.are.equal(2, listing_calls)
  end)

  it("reports deferred show exceptions once and clears current for the next action", function()
    targets = { target("a"), target("b") }
    targets[2].failure = "show failed"
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.show()
    assert.are.equal(0, targets[1].shown + targets[2].shown)
    choice(items[2])
    assert.are.same({ "show failed" }, notes)
    targets[2].failure = nil
    Pigeon.show()
    assert.are.equal(1, targets[2].shown)
    choose_target("b")
    assert.are.equal(2, targets[2].shown)
    assert.are.equal(0, targets[1].shown)
    assert.are.equal(2, listing_calls)
  end)

  it("cancels deferred selection quietly without sending", function()
    targets = { target("a"), target("b") }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    choice(nil)
    assert.are.same({}, notes)
    assert.are.same({}, targets[1].sent)
  end)

  it("offers tools without creating implicitly when a capable backend has no targets", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    assert.are.equal(2, #items)
    assert.are.same({}, notes)
    assert.are.equal(0, create_calls)
    choice(nil)
  end)

  it("keeps current across setup and only changes on successful selection", function()
    local only = target("a")
    targets = { only, target("b") }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    choice(items[1])
    Pigeon.setup()
    Pigeon.show()
    send()
    assert.are.equal(1, only.shown)
    assert.are.equal(2, #only.sent)
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    choice(nil)
    send()
    assert.are.equal(3, #only.sent)
    Pigeon.pick()
    choice(items[2])
    send()
    assert.are.equal(1, #targets[2].sent)
    Pigeon.setup()
    Pigeon.pick()
    send()
    assert.are.same({ "hello" }, writes)
  end)

  it("marks rediscovered identities first and preserves old instance on cancel", function()
    local a, b = target("a"), target("b")
    targets = { a, b }
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    choice(items[2])
    local fresh = target("b")
    targets = { a, fresh }
    Pigeon.pick()
    assert.is_true(rawequal(fresh, items[1]))
    assert.are.equal(" b [current]", picker_opts.format_item(items[1]))
    assert.are.equal(" a", picker_opts.format_item(items[2]))
    choice(nil)
    assert.are.equal(1, b.shown)
    assert.are.equal(0, fresh.shown)
    send()
    assert.are.equal(1, #b.sent)
    assert.are.equal(0, #fresh.sent)
  end)

  it("clears current on evaluation exceptions without replaying the failed action", function()
    local dead = target("dead")
    targets = { dead }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    choose_target("dead")
    dead.eval_failure = "bad message"
    targets = { target("replacement") }
    send()
    assert.is_truthy(notes[1]:find("bad message", 1, true))
    assert.are.equal(1, listing_calls)
    Pigeon.show()
    assert.are.equal(2, listing_calls)
    assert.are.equal(0, targets[1].shown)
    choose_target("replacement")
    assert.are.equal(1, targets[1].shown)
    assert.are.equal(1, #dead.sent)
    assert.are.same({}, writes)
    assert.are.equal(1, #notes)
  end)

  it("reports discovery failures once through pick, send and show", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    listing_error = "cannot enumerate"
    Pigeon.pick()
    send()
    Pigeon.show()
    assert.are.same({ "cannot enumerate", "cannot enumerate", "cannot enumerate" }, notes)
    assert.are.equal(3, listing_calls)
    assert.is_nil(items)
  end)

  for _, mode in ipairs({ "failed", "empty" }) do
    it("preserves current when discovery is " .. mode, function()
      send()
      Pigeon.setup({ backend = { default = "tmux" } })
      offer_tools = false
      listing_error = mode == "failed" and "cannot enumerate" or nil
      Pigeon.pick()
      assert.are.equal(1, #notes)
      local reason = mode == "failed" and "cannot enumerate" or "no tmux targets or supported tools available"
      assert.is_truthy(notes[1]:find(reason, 1, true))
      assert.is_nil(items)
      send()
      assert.are.same({ "hello", "hello" }, writes)
      assert.are.equal(1, listing_calls)
      assert.are.equal(1, #notes)
    end)
  end

  it("continues a pending choice using the original backend despite setup", function()
    targets = { target("a"), target("b") }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    Pigeon.setup()
    choice(items[2])
    send()
    assert.are.equal(2, #targets[2].sent)
    assert.are.same({}, writes)
  end)

  it("creates and shows a chosen tool after confirmation without sending", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    assert.are.equal(0, create_calls)
    assert.are.equal(0, created.shown)
    choose_tool("codex")
    assert.are.same({ "codex" }, created_names)
    assert.are.equal(1, created.shown)
    assert.are.same({}, created.sent)
    Pigeon.setup()
    send()
    assert.are.equal(1, #created.sent)
    assert.are.same({}, writes)
  end)

  it("lists custom tools alongside existing targets and retains their creation choices", function()
    targets = { target("codex") }
    Pigeon.setup({
      tools = { receiver = { command = { "sh" } } },
      backend = { default = "tmux" },
    })
    Pigeon.pick()
    assert.are.equal(4, #items)
    assert.are.equal(targets[1], item("target", "codex"))
    assert.are.same(
      { " claude", " codex", " receiver" },
      { tostring(items[2]), tostring(items[3]), tostring(items[4]) }
    )
    choose_tool("receiver")
    assert.are.same({ "receiver" }, created_names)
    assert.are.equal(0, targets[1].shown)
    assert.are.equal(1, created.shown)
  end)

  it("sends the pending Message to a newly created tool without showing it", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    local message = Message.text("pending draft")
    send(message)
    choose_tool("codex")
    assert.are.same({ "pending draft" }, created.sent)
    assert.are.equal(0, created.shown)
    assert.are.equal(1, create_calls)
    send(message)
    assert.are.same({ "pending draft", "pending draft" }, created.sent)
    assert.are.equal(1, listing_calls)
  end)

  it("retains the picker's backend when setup changes before tool confirmation", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    Pigeon.setup()
    choose_tool("codex")
    send()
    assert.are.same({ "codex" }, created_names)
    assert.are.equal(1, #created.sent)
    assert.are.same({}, writes)
  end)

  it("reports creation failure once and discards the pending action without selecting", function()
    Pigeon.setup({ backend = { default = "tmux" } })
    created, creation_error = nil, "launch failed"
    send()
    choose_tool("codex")
    assert.are.same({ "launch failed" }, notes)
    assert.are.equal(1, create_calls)
    created, creation_error = target("retry"), nil
    send()
    assert.are.equal(2, listing_calls)
    choose_tool("claude")
    assert.are.equal(1, #created.sent)
  end)

  it("preserves current when creation is cancelled", function()
    send()
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    choice(nil)
    assert.are.same({}, notes)
    send()
    assert.are.same({ "hello", "hello" }, writes)
    assert.are.equal(1, listing_calls)
  end)

  it("clears the previous current when creation fails and selects on the next action", function()
    send()
    Pigeon.setup({ backend = { default = "tmux" } })
    Pigeon.pick()
    created, creation_error = nil, "launch failed"
    choose_tool("codex")
    assert.are.same({ "launch failed" }, notes)
    assert.are.equal(1, create_calls)
    created, creation_error = target("retry"), nil
    send()
    assert.are.same({ "hello" }, writes)
    assert.are.equal(2, listing_calls)
    assert.are.equal(1, create_calls)
    choose_tool("claude")
    assert.are.same({ "hello" }, created.sent)
    assert.are.same({ "launch failed" }, notes)
  end)

  it("clears a newly selected existing target when pick cannot show it", function()
    targets = { target("a"), target("b") }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    choose_target("a")
    Pigeon.pick()
    targets[2].failure = "no attached client"
    choose_target("b")
    assert.are.same({ "no attached client" }, notes)
    assert.are.equal(1, targets[2].shown)
    targets[2].failure = nil
    send()
    assert.are.equal(3, listing_calls)
    choose_target("b")
    assert.are.equal(1, #targets[1].sent)
    assert.are.equal(1, #targets[2].sent)
  end)

  for _, action in ipairs({ "pick", "show" }) do
    it("clears current after " .. action .. " fails to show a created receiver", function()
      Pigeon.setup({ backend = { default = "tmux" } })
      Pigeon[action]()
      created.failure = "no attached client"
      choose_tool("codex")
      assert.are.same({ "no attached client" }, notes)
      assert.are.equal(1, created.shown)
      created.failure = nil
      targets = { created }
      send()
      assert.are.equal(2, listing_calls)
      choose_target("new")
      assert.are.equal(1, create_calls)
      assert.are.equal(1, #created.sent)
    end)
  end

  it("reports rendering and write exceptions", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function()
      error("copy failed", 0)
    end
    send()
    assert.is_truthy(notes[1]:find("copy failed", 1, true))
    assert.are.equal(1, #notes)
  end)

  it("clears current when the clipboard write returns a failure status", function()
    send()
    local write = vim.fn.setreg
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function()
      return 1
    end
    send()
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("could not write the system clipboard", 1, true))
    vim.fn.setreg = write
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    assert.are.equal(1, listing_calls)
    choose_tool("codex")
    assert.are.same({ "hello" }, writes)
    assert.are.same({ "hello" }, created.sent)
  end)

  it("reports status without discovering targets or loading backends", function()
    Pigeon.status()
    assert.are.same({ "pigeon: target: not chosen yet (default: clipboard)" }, notes)
    assert.are.equal(0, listing_calls)
    assert.is_nil(package.loaded["aviary.pigeon.backends.clipboard"])
  end)
  for _, action in ipairs({ "show", "send" }) do
    it("uses the agreed recovery policy after failure in " .. action, function()
      local old, replacement = target("old"), target("replacement")
      targets = { old }
      Pigeon.setup({ backend = { default = "tmux" } })
      send()
      choose_target("old")
      old.missing = true
      targets = { replacement }
      local message = Message.text("retained message")
      if action == "send" then
        Pigeon.send(message)
      else
        Pigeon.show()
      end
      assert.are.equal(1, listing_calls)
      assert.are.equal(1, #notes)
      if action == "send" then
        Pigeon.send(message)
      else
        Pigeon.show()
      end
      assert.are.equal(2, listing_calls)
      choose_target("replacement")
      assert.are.equal(action == "show" and 1 or 0, replacement.shown)
      assert.are.same(action == "send" and { "retained message" } or {}, replacement.sent)
      assert.are.equal(1, #old.sent)
    end)
  end

  it("keeps current empty when reselection is cancelled after an action failure", function()
    local old = target("old")
    targets = { old }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    choose_target("old")
    old.missing = true
    targets = { target("replacement") }
    Pigeon.show()
    Pigeon.pick()
    choice(nil)
    Pigeon.show()
    assert.are.equal(3, listing_calls)
    assert.are.equal(1, #notes)
    choose_target("replacement")
    assert.are.equal(1, targets[1].shown)
    assert.are.equal(1, #old.sent)
  end)

  it("ends a failed deferred action without reopening the picker", function()
    local old, replacement = target("old"), target("replacement")
    targets = { old }
    Pigeon.setup({ backend = { default = "tmux" } })
    send()
    local pending = choice
    local stale = item("target", "old")
    old.missing = true
    targets = { replacement }
    pending(stale)
    assert.are.equal(1, listing_calls)
    assert.are.equal(1, #notes)
    Pigeon.pick()
    assert.are.equal(2, listing_calls)
    choose_target("replacement")
    send()
    assert.are.equal(1, #replacement.sent)
    assert.are.same({}, old.sent)
    assert.are.equal(1, #notes)
  end)
end)
