---@module 'luassert'

--- Run real feature entries in a fresh editor.
---@param body string
local function check(body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/composition.lua"
  local fixture = [=[
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local aviary = require("aviary")
]=]
  vim.fn.writefile(vim.split(fixture .. body, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, { text = true })
    :wait(10000)
  vim.fn.delete(dir, "rf")
  assert.are.equal(0, result.code, result.stderr)
  assert.are.equal("", result.stderr)
end

describe("aviary feature composition", function()
  it("keeps features lazy until configured", function()
    check([=[
aviary.setup({})
for _, name in ipairs({ "hawk", "pigeon" }) do assert(package.loaded["aviary." .. name] == nil) end
aviary.setup({ pigeon = { view = { width = 80 } } })
assert(package.loaded["aviary.pigeon"] ~= nil)
assert(package.loaded["aviary.hawk"] == nil)
]=])
  end)

  it("exposes Pigeon and Hawk as the original cached modules", function()
    check([=[
for _, name in ipairs({ "pigeon", "hawk" }) do
  assert(aviary[name] == package.loaded["aviary." .. name])
  assert(aviary[name] == aviary[name])
end
]=])
  end)
end)
