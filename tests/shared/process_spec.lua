---@module 'luassert'

local Process = require("aviary.shared.process")

describe("aviary.shared.process", function()
  local dir
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)
  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("passes literal arguments, cwd, environment and stdin to the command", function()
    local literal = "$(printf expanded) *"
    local result = Process.run({
      "sh",
      "-c",
      'printf "%s\\n" "$PWD" "$AVIARY_PROCESS_TEST" "$1"; cat',
      "process-test",
      literal,
    }, { cwd = dir, env = { AVIARY_PROCESS_TEST = "test value" }, stdin = "input\n" })
    assert.are.equal(0, result.code)
    assert.are.equal(0, result.signal)
    assert.are.equal(dir .. "\ntest value\n" .. literal .. "\ninput\n", result.stdout)
    assert.are.equal("", result.stderr)
  end)

  it("preserves a nonzero exit code and both output streams for the caller", function()
    local result = Process.run({ "sh", "-c", "printf output; printf '  failure\\n' >&2; exit 1" })
    assert.are.equal(1, result.code)
    assert.are.equal("output", result.stdout)
    assert.are.equal("  failure\n", result.stderr)
  end)

  it("reports commands that cannot start without raising", function()
    local result = Process.run({ vim.fs.joinpath(dir, "missing-command") })
    assert.are.equal(-1, result.code)
    assert.are.equal(0, result.signal)
    assert.are.equal("", result.stdout)
    assert.is_true(#result.stderr > 0)
  end)

  it("preserves a termination signal independently of the exit code", function()
    local result = Process.run({ "sh", "-c", "kill -TERM $$" })
    assert.are.equal(15, result.signal)
    assert.are.equal("", result.stdout)
  end)
end)
