--- Shared helpers for Weaver specs.
---@class aviary.test.weaver.Helpers
---@field delivery fun(on_message: fun(message: aviary.shared.Message)): fun() replace root delivery and return its restoration
local M = {}

--- An arbitrary destination policy, independent of receiving feature defaults.
---@param path string
---@param first? integer
---@param last? integer
---@return string
function M.format(path, first, last)
  return path .. (first and "[" .. first .. (last and "," .. last or "") .. "]" or "")
end

--- Clear loaded Weaver modules and their runtime state.
function M.reload_weaver()
  for name in pairs(package.loaded) do
    if name == "aviary.weaver" or name:find("^aviary%.weaver%.") == 1 then
      package.loaded[name] = nil
    end
  end
end

function M.delivery(on_message)
  local aviary = require("aviary")
  local original = rawget(aviary, "pigeon")
  aviary.pigeon = { send = on_message }
  return function()
    aviary.pigeon = original
  end
end

--- Create a real scratch buffer with `lines`, optionally named `name`.
---@param lines string|string[]
---@param name? string
---@return integer
function M.buffer(lines, name)
  local body
  if type(lines) == "string" then
    body = vim.split(lines, "\n", { plain = true })
  else
    body = lines
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  if name and name ~= "" then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

---@param buf integer
function M.wipe(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M.clear_picker_mock()
  package.loaded["aviary.weaver.picker"] = nil
end

--- Capture messages emitted during fn(), restoring the handler even on failure.
---@param fn fun()
---@return string[]
function M.notifications(fn)
  local seen = {}
  local original = vim.notify
  ---@param msg string
  ---@param _ integer?
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, _)
    seen[#seen + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err)
  end
  return seen
end

return M
