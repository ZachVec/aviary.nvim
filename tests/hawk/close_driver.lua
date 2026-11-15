-- Native exit must run outside the suite's editor. The cancel scenario attaches
-- a real UI to a child so its confirmation dialog accepts an explicit Cancel.
local scenario = assert(arg[1])
if scenario == "cancel" then
  local channel = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" },
    { rpc = true }
  )
  assert(channel > 0)
  vim.rpcrequest(channel, "nvim_ui_attach", 80, 24, { rgb = true })
  vim.rpcrequest(channel, "nvim_exec_lua", 'arg = {"ui"}; dofile("tests/hawk/close_driver.lua")', {})
  vim.wait(100)
  vim.rpcrequest(channel, "nvim_input", "c")
  vim.wait(100)
  assert(vim.rpcrequest(channel, "nvim_exec_lua", "return _G.check_cancelled_exit()", {}) == "checked")
  vim.fn.jobstop(channel)
  io.write("checked\n")
  vim.cmd("qa!")
  return
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local Async = require("aviary.shared.async")
local Data = require("aviary.hawk.review.review")
local Review = require("aviary.hawk.review")
local api = vim.api
local reads, cancelled, close_calls = 0, 0, 0
-- Keep the concrete metadata flow pending through native exit/confirmation.
Data.start = function()
  return function() end
end
Data.read = function(ctx)
  reads = reads + 1
  Async({ "hawk-exit-spec" }):run(ctx):wait()
  return {}, nil
end
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.jobstart = function()
  return reads
end
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.jobstop = function()
  cancelled = cancelled + 1
  return 1
end
local tab = assert(Review.create(function()
  close_calls = close_calls + 1
end))
---@cast tab any native resource inspection
local layout = {
  buf = tab.bufnr,
  windows = { tab.old_win, tab.new_win },
}
local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(1000, function()
    return done
  end))
end
flush()
vim.cmd.tabonly()
local source, path
if scenario == "refused" or scenario == "confirm" or scenario == "ui" then
  source = api.nvim_create_buf(true, false)
  path = vim.fn.tempname()
  api.nvim_buf_set_name(source, path)
  api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved" })
  vim.o.hidden = true
  vim.o.confirm = scenario ~= "refused"
end
local function check()
  assert(reads > 0 and cancelled == reads and close_calls == 1)
  assert(not api.nvim_buf_is_valid(layout.buf))
  for _, win in ipairs(layout.windows) do
    if api.nvim_win_is_valid(win) then
      assert(not vim.wo[win].winfixbuf)
    end
  end
end
local armed = true
api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if armed then
      check()
      if scenario == "confirm" then
        assert(vim.fn.readfile(assert(path))[1] == "unsaved")
        vim.fn.delete(path)
      end
      io.write("checked\n")
    end
  end,
})
if scenario == "ui" then
  _G.check_cancelled_exit = function()
    check()
    assert(api.nvim_buf_is_valid(source) and vim.bo[source].modified)
    assert(#api.nvim_list_tabpages() == 1)
    return "checked"
  end
end
api.nvim_set_current_win(layout.windows[1])
api.nvim_win_close(layout.windows[1], false)
if scenario == "ui" then
  return -- parent answers the scheduled qall's dialog
end
flush() -- successful qall exits the process before this returns
assert(scenario == "refused")
check()
assert(api.nvim_buf_is_valid(source) and vim.bo[source].modified)
io.write("checked\n")
armed = false
vim.cmd("qa!")
