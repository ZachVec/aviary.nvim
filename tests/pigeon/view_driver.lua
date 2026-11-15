-- Invoked only by view.py; exercise public actions in independent Neovims.
vim.opt.runtimepath:prepend(assert(vim.env.AVIARY_TEST_ROOT))
local pigeon = require("aviary").pigeon
local Message = require("aviary.shared.message")
local Process = require("aviary.shared.process")
local Helpers = dofile(vim.fs.joinpath(assert(vim.env.AVIARY_TEST_ROOT), "tests", "pigeon", "helpers.lua"))
local function setup(opts)
  opts.backend = opts.backend or {}
  opts.backend.default = opts.backend.default or "tmux"
  opts.backend.tmux = opts.backend.tmux or {}
  return pigeon.setup(opts)
end
local errors = {}
local reuse
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(text, level)
  if level == vim.log.levels.WARN then
    errors[#errors + 1] = text
  end
end
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.select = function(items, _, done)
  for _, item in ipairs(items) do
    if
      (reuse and tostring(item):find("[" .. reuse:gsub("^0+", "") .. "]", 1, true))
      or (not reuse and tostring(item) == " codex")
    then
      done(item)
      return
    end
  end
  error("missing requested picker choice")
end
setup({
  tools = {
    codex = {
      command = {
        assert(vim.env.AVIARY_TEST_PYTHON),
        assert(vim.env.AVIARY_TEST_RECEIVER),
        assert(vim.env.AVIARY_TEST_RECEIVER_MODE),
      },
    },
  },
  backend = { default = "tmux" },
})
local backend = require("aviary.pigeon.backends.tmux")
local existing = Helpers.targets(backend)
pigeon.pick()
pigeon.send(Message.text("PERSISTENT_DRAFT"))
assert(#errors == 0, table.concat(errors, "\n"))
for _, target in ipairs(Helpers.targets(backend)) do
  if not vim.tbl_contains(existing, target) then
    ---@cast target aviary.pigeon.TmuxTarget
    io.stdout:write(vim.json.encode(target) .. "\n")
    io.stdout:flush()
    reuse = target.instance
  end
end
for command in io.lines() do
  if command == "show" then
    pigeon.show()
  elseif command == "double-show" then
    pigeon.show()
    pigeon.show()
  elseif command:match("^reuse:") then
    reuse = command:sub(7)
    pigeon.pick()
  elseif command == "resize" then
    setup({ backend = { tmux = { width = "70", height = "20" } } })
    pigeon.show()
  elseif command == "ratio-resize" then
    setup({ backend = { tmux = { width = "33%", height = "62%" } } })
    pigeon.show()
  elseif command == "full-size" then
    setup({ backend = { tmux = { width = "100%", height = "100%" } } })
    pigeon.show()
  elseif command == "fail-start" then
    local run = Process.run
    ---@diagnostic disable-next-line: duplicate-set-field
    Process.run = function(argv, opts)
      if vim.tbl_contains(argv, "respawn-pane") then
        return { code = 1, signal = 0, stdout = "", stderr = "injected attach failure" }
      end
      return run(argv, opts)
    end
    pigeon.show()
    Process.run = run
    assert(#errors == 1 and errors[1]:find("injected attach failure", 1, true), table.concat(errors, "\n"))
    errors = {}
  elseif command == "conflict" or command == "alias-conflict" then
    if command == "alias-conflict" then
      setup({ backend = { tmux = { close = "c-." } } })
    end
    local saved_health = vim.health
    vim.health = setmetatable({
      warn = function(text)
        errors[#errors + 1] = text
      end,
    }, {
      __index = function()
        return function() end
      end,
    })
    require("aviary.pigeon.health").check()
    vim.health = saved_health
    assert(#errors == 1 and errors[1]:find("used by the outer tmux", 1, true), table.concat(errors, "\n"))
    errors = {}
    setup({ backend = { tmux = { close = "C-." } } })
  elseif command == "quit" then
    assert(#errors == 0, table.concat(errors, "\n"))
    break
  elseif command ~= "check" then
    error("unknown test command: " .. command)
  end
  assert(#errors == 0, table.concat(errors, "\n"))
  io.stdout:write("ok\n")
  io.stdout:flush()
end
