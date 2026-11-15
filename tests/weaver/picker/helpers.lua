--- Shared helpers for the picker specs.
local M = {}

--- Clear loaded picker modules and configuration.
function M.reload_picker()
  for name in pairs(package.loaded) do
    if
      name == "aviary.weaver.picker"
      or name:find("^aviary%.weaver%.picker%.") == 1
      or name == "aviary.weaver.config"
    then
      package.loaded[name] = nil
    end
  end
end

--- Exercise a backend's buffer filter against real file and scratch buffers.
---@param filter fun(buf: integer): boolean
function M.check_buffer_filter(filter)
  local path = vim.fn.tempname()
  vim.fn.writefile({ "on disk" }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local scratch = vim.api.nvim_create_buf(true, true)
  local ok, err = pcall(function()
    assert.is_true(filter(buf))
    assert.is_false(filter(scratch))
    vim.bo[buf].buflisted = false
    assert.is_false(filter(buf))
    vim.bo[buf].buflisted = true
    vim.bo[buf].buftype = "nofile"
    assert.is_false(filter(buf))
    vim.bo[buf].buftype = ""
    vim.fn.delete(path)
    assert.is_false(filter(buf))
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(scratch, { force = true })
  vim.fn.delete(path)
  assert(ok, err)
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
