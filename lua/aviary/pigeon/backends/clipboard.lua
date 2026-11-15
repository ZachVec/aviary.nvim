--- The clipboard is one existing destination and Choice with synchronous operations.
local Config = require("aviary.pigeon.config")
local Notify = require("aviary.shared.notify")

---@class aviary.pigeon.ClipboardTarget: aviary.pigeon.Target, aviary.pigeon.Choice
local Target = {}

---@class aviary.pigeon.backends.clipboard: aviary.pigeon.Backend
local M = {}
Target.__index = Target
local target = setmetatable({}, Target)

function Target:__tostring()
  return "clipboard"
end

function Target:resolve()
  return self
end

function Target:show()
  local text = vim.fn.getreg("+")
  Notify.info(text == "" and "pigeon: clipboard is empty" or text)
end

function Target:eval(message)
  return (assert(message:eval({ format = Config().format })))
end

function Target:send(text)
  assert(vim.fn.setreg("+", text, "v") == 0, "could not write the system clipboard")
end

function M.list()
  return { target }
end

return M
