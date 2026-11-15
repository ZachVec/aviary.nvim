---@module 'luassert'

--- Run real feature entries in a fresh editor; fake delivery backends and picker UIs.
---@param body string Lua assertions sharing the fixture's source, paths and UI controls
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

local writes, notes = {}, {}
local picker_closed, require_closed = false, false
local has = vim.fn.has
vim.fn.has = function(name)
  if name == "clipboard" then return 1 end
  return has(name)
end
vim.fn.setreg = function(register, text, kind)
  assert(register == "+" and kind == "v")
  assert(not require_closed or picker_closed, "delivery ran before picker cleanup")
  writes[#writes + 1] = text
  return 0
end
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

local function confirm_paths()
  local items = { { file = path }, { file = other } }
  picked_opts.confirm({
    selected = function(_, opts)
      assert(opts.fallback == true)
      return items
    end,
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
for _, name in ipairs({ "prompt", "files", "buffers", "text", "setup" }) do
  assert(type(weaver[name]) == "function")
end
aviary.setup({})
for _, name in ipairs({ "hawk", "weaver", "pigeon" }) do
  assert(package.loaded["aviary." .. name] == nil)
end
aviary.setup({ weaver = { picker = "snacks" } })
assert(package.loaded["aviary.weaver"] ~= nil)
assert(weaver == aviary.weaver and weaver ~= package.loaded["aviary.weaver"])
assert(package.loaded["aviary.pigeon"] == nil)
assert(package.loaded["aviary.hawk"] == nil)
]=])
  end)

  it("exposes Pigeon and Hawk as the original cached modules", function()
    check([=[
for _, name in ipairs({ "pigeon", "hawk" }) do
  local feature = aviary[name]
  assert(feature == package.loaded["aviary." .. name])
  assert(feature == aviary[name])
end
assert(package.loaded["aviary.weaver"] == nil)
]=])
  end)

  for _, name in ipairs({ "files", "buffers" }) do
    it("delivers selected " .. name .. " references through Pigeon after UI cleanup", function()
      check(([=[
aviary.setup({ weaver = { picker = "snacks" } })
require_closed = true
aviary.weaver.%s()
assert(picked_source == %q)
assert(#writes == 0)
confirm_paths()
assert(writes[1] == path .. "\n" .. other)
assert(package.loaded["aviary.hawk"] == nil)
]=]):format(name, name))
    end)

    it("sends resumed " .. name .. " selections through the current Pigeon target", function()
      check(([=[
local deliveries = {}
local function target(id)
  return {
    resolve = function(self) return self end,
    show = function() end,
    eval = function(_, message)
      return assert(message:eval({ format = function(file) return file end }))
    end,
    send = function(_, text)
      assert(picker_closed, "delivery ran before picker cleanup")
      deliveries[#deliveries + 1] = {
        id = id,
        text = text,
      }
    end,
  }
end
local first, second = target("first"), target("second")
package.loaded["aviary.pigeon.backends.tmux"] = {
  list = function() return { first, second } end,
}
aviary.setup({ pigeon = { backend = { default = "tmux" } } })
aviary.pigeon.pick()
choose(choices[1])
aviary.weaver.%s()
local confirm = picked_opts.confirm
local function confirm_selection(file)
  picker_closed = false
  confirm({
    selected = function() return { { file = file } } end,
    close = function()
      vim.schedule(function() picker_closed = true end)
    end,
  })
end
confirm_selection(path)
assert(#deliveries == 0)
assert(vim.wait(1000, function() return #deliveries == 1 end))
assert(deliveries[1].id == "first" and deliveries[1].text == path)

aviary.pigeon.pick()
choose(choices[2])
assert(picked_opts.confirm == confirm)
confirm_selection(other)
assert(#deliveries == 1)
assert(vim.wait(1000, function() return #deliveries == 2 end))
assert(deliveries[2].id == "second" and deliveries[2].text == other)
assert(#notes == 0)
]=]):format(name))
    end)
  end

  it("delivers the invoking prompt context after a deferred choice", function()
    check([=[
aviary.weaver.prompt()
assert(#writes == 0)
vim.api.nvim_buf_set_name(source, dir .. "/renamed.lua")
vim.api.nvim_set_current_buf(vim.fn.bufadd(other))
choose("{line}")
assert(#writes == 1 and writes[1] == path .. " :L2 ")
]=])
  end)

  it("captures text and delivers immediately to the sole clipboard target", function()
    check([=[
assert(aviary.weaver.text() == nil)
assert(choices == nil)
assert(#writes == 1 and writes[1] == "two")
local calls = 0
local send = aviary.pigeon.send
aviary.pigeon.send = function(...)
  assert(select("#", ...) == 1)
  local message = ...
  calls = calls + 1
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { "later" })
  assert(message:eval({ format = function(path) return path end }) == "two")
end
local result = aviary.weaver.text()
aviary.pigeon.send = send
assert(result == nil and calls == 1)
]=])
  end)

  it("freezes Visual prompt context across template and target selection", function()
    check([=[
local function target()
  return {
    resolve = function(self) return self end,
    eval = function(_, message)
      return assert(message:eval({format = function(file, first, last)
        return file .. ":" .. first .. "-" .. last
      end}))
    end,
    send = function(_, text) writes[#writes + 1] = text end,
  }
end
package.loaded["aviary.pigeon.backends.tmux"] = {
  list = function() return { target(), target() } end,
}
aviary.setup({ pigeon = { backend = { default = "tmux" } } })
vim.cmd("normal! 3GVk")
aviary.weaver.prompt()
assert(#writes == 0)
vim.api.nvim_buf_set_name(source, dir .. "/renamed.lua")
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "changed" })
choose("{line}")
assert(#writes == 0)
choose(choices[1])
assert(#writes == 1 and writes[1] == path .. ":2-3 ")
]=])
  end)

  it("cancels a deferred prompt without sending or notifying", function()
    check([=[
aviary.weaver.prompt()
choose(nil)
assert(#writes == 0 and #notes == 0)
]=])
  end)

  it("cancels a target choice without delivering captured text or notifying", function()
    check([=[
package.loaded["aviary.pigeon.backends.tmux"] = {
  list = function()
    local choice = { resolve = function() error("cancelled selection must not create a tool") end }
    return { choice, choice }
  end,
}
aviary.setup({ pigeon = { backend = { default = "tmux" } } })
aviary.weaver.text()
assert(#writes == 0)
choose(nil)
assert(#writes == 0 and #notes == 0)
]=])
  end)
end)
