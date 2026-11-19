---@module 'luassert'

--- Run real feature entries in a fresh editor; substitute tmux/Terminal and picker UIs.
---@param body string
local function check(body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/composition.lua"
  local fixture = ([=[
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local aviary = require("aviary")
local dir = %q
local path, other = dir .. "/a.lua", dir .. "/b.lua"
vim.fn.writefile({ "one", "two", "three" }, path)
vim.fn.writefile({ "other" }, other)
vim.cmd.edit(path)
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local writes, recipients, notes = {}, {}, {}
local picker_closed, require_closed = false, false
vim.notify = function(text) notes[#notes + 1] = text end
local choices, choose
vim.ui.select = function(items, _, done) choices, choose = items, done end
local picked_source, picked_opts
package.preload["snacks"] = function()
  return { picker = {
    util = { path = function(item) return item.file end },
    pick = function(name, opts) picked_source, picked_opts = name, opts end,
  } }
end
local function attach(format)
  local function target(name)
    local self = {
      attach = function() return { "sh", "-c", "sleep 300" } end,
      retarget = function() end,
      eval = function(_, message)
        return assert(message:eval({ format = format or require("aviary.pigeon.config")().format }))
      end,
      send = function(_, text)
        assert(not require_closed or picker_closed, "delivery ran before picker cleanup")
        writes[#writes + 1], recipients[#recipients + 1] = text, name
      end,
    }
    function self:id() return name end
    function self:resolve() return self end
    return setmetatable(self, { __tostring = function() return name end })
  end
  local targets = { target("first"), target("second") }
  package.loaded["aviary.pigeon.backends"] = {
    list = function() return { targets[1], targets[2] } end,
  }
  local window = vim.api.nvim_get_current_win()
  aviary.pigeon.pick(); choose(targets[1]); choices, choose = nil, nil
  vim.api.nvim_set_current_win(window)
  return function()
    local restore = vim.api.nvim_get_current_win()
    aviary.pigeon.pick(); choose(targets[2]); choices, choose = nil, nil
    vim.api.nvim_set_current_win(restore)
  end
end
local function confirm_paths()
  local items = { { file = path }, { file = other } }
  picked_opts.confirm({
    selected = function(_, opts) assert(opts.fallback == true); return items end,
    close = function() picker_closed = true end,
  })
  items[1].file = "/later.lua"
  assert(vim.wait(1000, function() return #writes == 1 end))
  assert(choices == nil)
end
]=]):format(dir)
  vim.fn.writefile(vim.split(fixture .. body, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, { text = true })
    :wait(10000)
  vim.fn.delete(dir, "rf")
  assert.are.equal(0, result.code, result.stderr)
  assert.are.equal("", result.stderr)
end

describe("aviary feature workflows", function()
  it("keeps features lazy until configured or invoked", function()
    check([=[
local weaver = aviary.weaver
for _, name in ipairs({ "prompt", "files", "buffers", "text", "setup" }) do assert(type(weaver[name]) == "function") end
aviary.setup({})
for _, name in ipairs({ "hawk", "weaver", "pigeon" }) do assert(package.loaded["aviary." .. name] == nil) end
aviary.setup({ weaver = { picker = "snacks" } })
assert(package.loaded["aviary.weaver"] ~= nil)
assert(weaver == aviary.weaver and weaver ~= package.loaded["aviary.weaver"])
assert(package.loaded["aviary.pigeon"] == nil and package.loaded["aviary.hawk"] == nil)
]=])
  end)
  it("exposes Pigeon and Hawk as the original cached modules", function()
    check([=[
for _, name in ipairs({ "pigeon", "hawk" }) do
  assert(aviary[name] == package.loaded["aviary." .. name])
  assert(aviary[name] == aviary[name])
end
assert(package.loaded["aviary.weaver"] == nil)
]=])
  end)
  for _, name in ipairs({ "files", "buffers" }) do
    it("delivers selected " .. name .. " through Pigeon after UI cleanup", function()
      check(([=[
attach()
aviary.setup({ weaver = { picker = "snacks" } })
require_closed = true
aviary.weaver.%s()
assert(picked_source == %q and #writes == 0)
confirm_paths()
assert(writes[1] == path .. "\n" .. other)
assert(package.loaded["aviary.hawk"] == nil)
]=]):format(name, name))
    end)
    it("sends resumed " .. name .. " selections through the live Pigeon Agent", function()
      check(([=[
local switch = attach()
aviary.setup({ weaver = { picker = "snacks" } })
require_closed = true
aviary.weaver.%s()
local confirm = picked_opts.confirm
local function confirm_selection(file)
  picker_closed = false
  confirm({
    selected = function() return { { file = file } } end,
    close = function() vim.schedule(function() picker_closed = true end) end,
  })
end
confirm_selection(path)
assert(#writes == 0)
assert(vim.wait(1000, function() return #writes == 1 end))
assert(recipients[1] == "first" and writes[1] == path)
switch()
confirm_selection(other)
assert(#writes == 1)
assert(vim.wait(1000, function() return #writes == 2 end))
assert(recipients[2] == "second" and writes[2] == other and #notes == 0)
]=]):format(name))
    end)
  end
  it("delivers the invoking prompt context after a deferred choice", function()
    check([=[
attach()
aviary.weaver.prompt()
assert(#writes == 0)
vim.api.nvim_buf_set_name(source, dir .. "/renamed.lua")
vim.api.nvim_set_current_buf(vim.fn.bufadd(other))
choose("{line}")
assert(#writes == 1 and writes[1] == path .. " :L2 ")
]=])
  end)
  it("captures text immediately before delivering to the live target", function()
    check([=[
attach()
assert(aviary.weaver.text() == nil)
assert(choices == nil and #writes == 1 and writes[1] == "two")
local calls = 0
aviary.pigeon.send = function(message)
  calls = calls + 1
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { "later" })
  assert(message:eval({ format = function(file) return file end }) == "two")
end
assert(aviary.weaver.text() == nil and calls == 1)
]=])
  end)
  it("freezes Visual prompt context across template selection", function()
    check([=[
attach(function(file, first, last) return file .. ":" .. first .. "-" .. last end)
vim.cmd("normal! 3GVk")
aviary.weaver.prompt()
vim.api.nvim_buf_set_name(source, dir .. "/renamed.lua")
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "changed" })
choose("{line}")
assert(#writes == 1 and writes[1] == path .. ":2-3 ")
]=])
  end)
  it("cancels a deferred prompt without sending or notifying", function()
    check([=[
attach()
aviary.weaver.prompt(); choose(nil)
assert(#writes == 0 and #notes == 0)
]=])
  end)
  it("reports Weaver sends without an attached target without selecting or delivering", function()
    check([=[
aviary.weaver.text()
assert(choices == nil and #writes == 0 and #notes == 1)
assert(notes[1]:find("no attached Agent", 1, true))
]=])
  end)
end)
