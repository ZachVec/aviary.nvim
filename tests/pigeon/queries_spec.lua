---@module 'luassert'

local Helpers = require("pigeon.helpers")

describe("pigeon tmux composition", function()
  local backend, Cli, data, live, staged, focus_calls, saved_select, saved_create, saved_executable
  before_each(function()
    Helpers.reload_pigeon()
    Cli = require("aviary.pigeon.backends.tmux.cli")
    data = { instance = string.rep("a", 24), tool = "codex", cwd = "/agent/work" }
    live, staged, focus_calls = true, nil, {}
    ---@diagnostic disable: duplicate-set-field
    Cli.list = function()
      return { { name = data.instance, tool = data.tool, cwd = data.cwd } }
    end
    Cli.create = function() end
    Cli.focus = function(...)
      focus_calls[#focus_calls + 1] = { ... }
      if not live then
        error("command failed", 0)
      end
    end
    Cli.paste = function(address, text)
      staged = { address, text }
      if not live then
        error("command failed", 0)
      end
    end
    saved_select, saved_create, saved_executable = vim.ui.select, vim.api.nvim_create_autocmd, vim.fn.executable
    vim.api.nvim_create_autocmd = function()
      error("must not register editor-exit cleanup")
    end
    vim.fn.executable = function()
      error("must not preflight executables")
    end
    ---@diagnostic enable: duplicate-set-field
    backend = require("aviary.pigeon.backends.tmux")
  end)
  after_each(function()
    vim.ui.select, vim.api.nvim_create_autocmd, vim.fn.executable = saved_select, saved_create, saved_executable
    Helpers.reload_pigeon()
  end)

  it("maps native session fields to Targets and adds sorted tool Choices", function()
    local choices = backend.list()
    assert.are.same(data, choices[1]:resolve())
    assert.are.same({ " claude", " codex" }, { tostring(choices[2]), tostring(choices[3]) })
  end)

  it("propagates unexpected discovery exceptions to the caller", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    Cli.list = function()
      error("unexpected discovery error", 0)
    end
    assert.has_error(backend.list, "unexpected discovery error")
  end)

  it("generates target identity and supplies native session/window names and options", function()
    local captured
    ---@diagnostic disable-next-line: duplicate-set-field
    Cli.create = function(name, window, command, cwd, options)
      captured = { name, window, command, cwd, options }
    end
    local target = backend.list()[3]:resolve()
    assert.are.equal("codex", target.tool)
    assert.are.equal(target.instance, captured[1])
    assert.are.equal("codex", captured[2])
    assert.are.same({ "codex" }, captured[3])
    assert.are.equal(vim.fs.normalize(vim.fn.getcwd()), captured[4])
    assert.are.equal("codex", captured[5]["@pigeon_tool"])
    assert.are.equal("on", captured[5]["detach-on-destroy"])
  end)

  it("evaluates before paste and reports an absent destination from the actual operation", function()
    local evaluated
    live = false
    local target = backend.list()[1]:resolve()
    local text = target:eval({
      eval = function(_, context)
        evaluated = context
        return "draft"
      end,
    })
    assert.are.equal("draft", text)
    assert.is_nil(staged)
    assert.has_error(function()
      target:send(text)
    end, "command failed")
    assert.are.equal(data.cwd, evaluated.cwd)
    assert.are.same({ "=" .. data.instance .. ":", "draft" }, staged)
  end)

  it("delegates display state to CLI and propagates its exceptions", function()
    local target = backend.list()[1]:resolve()
    assert.is_nil(target:show())
    assert.is_nil(target:show())
    live = false
    assert.has_error(function()
      target:show()
    end, "command failed")
    live = true
    assert.is_nil(target:show())
    assert.are.equal(4, #focus_calls)
    for _, call in ipairs(focus_calls) do
      assert.are.same({ data.instance }, call)
    end
  end)

  it("warns without staging and clears current when evaluation returns a failure", function()
    local selections = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      selections = selections + 1
      done(items[1])
    end
    local pigeon = require("aviary").pigeon
    pigeon.setup({ backend = { default = "tmux" } })
    local notes = Helpers.notifications(function()
      pigeon.send({
        eval = function()
          return nil, "declined reference"
        end,
      })
    end)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("declined reference", 1, true))
    assert.is_nil(staged)
    pigeon.send({
      eval = function()
        return "next draft"
      end,
    })
    assert.are.equal(2, selections)
    assert.are.same({ "=" .. data.instance .. ":", "next draft" }, staged)
  end)

  it("clears current after failed paste and selects only on a new explicit action", function()
    local choices, confirm, evaluations, attempts = nil, nil, {}, 0
    ---@diagnostic disable: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, confirm = items, done
    end
    Cli.paste = function()
      attempts = attempts + 1
      data = { instance = string.rep("b", 24), tool = "codex", cwd = "/other" }
      if attempts == 1 then
        error("write failed", 0)
      end
    end
    ---@diagnostic enable: duplicate-set-field
    local pigeon = require("aviary").pigeon
    pigeon.setup({ backend = { default = "tmux" } })
    pigeon.send({
      eval = function(_, context)
        evaluations[#evaluations + 1] = context.cwd
        return "retained draft"
      end,
    })
    local message = {
      eval = function(_, context)
        evaluations[#evaluations + 1] = context.cwd
        return "retained draft"
      end,
    }
    local notes = Helpers.notifications(function()
      assert(confirm)(assert(choices)[1])
    end)
    assert.are.same({ "write failed" }, notes)
    assert.are.same({ "/agent/work" }, evaluations)
    assert.are.equal(1, attempts)
    confirm = nil
    pigeon.send(message)
    assert(confirm)(assert(choices)[1])
    assert.are.same({ "/agent/work", "/other" }, evaluations)
    assert.are.equal(2, attempts)
  end)
end)
