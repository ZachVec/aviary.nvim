---@module 'luassert'
describe("pigeon Neovim Terminal lifecycle", function()
  it("routes live selections and releases only owned resources through actual TUI lifecycle events", function()
    local result = vim
      .system({ "python3", "tests/pigeon/view.py", "--nvim", vim.v.progpath, "--cycles", "5" }, { text = true })
      :wait(60000)
    assert.are.equal(0, result.code, result.stdout .. result.stderr)
    local path = assert(result.stdout:match("REPORT ([^\r\n]+)"))
    local report = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true } })
    assert.are.equal(12, #report.checks)
    assert.is_nil(report.error)
  end)
end)
