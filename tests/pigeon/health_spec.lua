---@module 'luassert'
---@diagnostic disable: duplicate-set-field
---@type aviary.pigeon.TestHelpers
local Helpers = require("pigeon.helpers")
local Process = require("aviary.shared.process")
describe("pigeon health", function()
  local saved_health, saved_executable, saved_run, saved_tmux, notes, version, executable
  before_each(function()
    Helpers.reload_pigeon()
    saved_health, saved_executable, saved_run, saved_tmux = vim.health, vim.fn.executable, Process.run, vim.env.TMUX
    notes, version, executable = {}, "tmux 3.8", true
    vim.env.TMUX = "/test,0,0"
    vim.health = {}
    for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
      vim.health[level] = function(text)
        notes[#notes + 1] = { level, text }
      end
    end
    vim.fn.executable = function()
      return executable and 1 or 0
    end
    Process.run = function(argv)
      assert.are.same({ "tmux", "-V" }, argv)
      return { code = 0, stdout = version, stderr = "" }
    end
  end)
  after_each(function()
    vim.health, vim.fn.executable, Process.run, vim.env.TMUX = saved_health, saved_executable, saved_run, saved_tmux
    Helpers.reload_pigeon()
  end)
  it("reports dependencies read-only without clipboard, bindings or source-pane requirements", function()
    require("aviary.pigeon.health").check()
    assert.are.same({ "ok", "tmux: tmux 3.8" }, notes[2])
    assert.are.same({ "ok", "tmux host context: available" }, notes[3])
    for _, note in ipairs(notes) do
      assert.are_not.equal("error", note[1])
    end
  end)
  it("reports missing executable and host context", function()
    executable, vim.env.TMUX = false, nil
    require("aviary.pigeon.health").check()
    assert.are.equal("error", notes[2][1])
    assert.are.equal("error", notes[3][1])
  end)
  it("reports unsupported tmux versions", function()
    version = "tmux 3.7"
    require("aviary.pigeon.health").check()
    assert.are.same({ "error", "tmux 3.8+ is required" }, notes[2])
  end)
end)
