local M = {}

--- An arbitrary destination policy, independent of receiving feature defaults.
---@param path string
---@param first? integer
---@param last? integer
---@return string
function M.format(path, first, last)
  return path .. (first and "[" .. first .. (last and "," .. last or "") .. "]" or "")
end

---@param directory string
---@param args string[]
---@return string
function M.git(directory, args)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = directory, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout or ""
end

---@return string
function M.repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  M.git(dir, { "init", "-q", "-b", "main" })
  M.git(dir, { "config", "user.email", "test@example.com" })
  M.git(dir, { "config", "user.name", "test" })
  return dir
end

---@param dir string
---@param name string
---@param lines string[]
---@return string
function M.write(dir, name, lines)
  local path = vim.fs.joinpath(dir, name)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

---@param dir string
function M.commit(dir)
  M.git(dir, { "add", "-A" })
  M.git(dir, { "commit", "-qm", "test" })
end

---@param path string
function M.edit(path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
end

---@param lhs string
function M.press(lhs)
  M.flush()
  local map = vim.fn.maparg(lhs, "n", false, true)
  assert(type(map.callback) == "function", "no callback for " .. lhs)
  map.callback()
end

--- Drain scheduled editor events before checking lifecycle effects.
function M.flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(100, function()
    return done
  end))
end

---@param source integer
---@param dir string
function M.cleanup(source, dir)
  if vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name:sub(1, #dir + 1) == dir .. "/" or vim.bo[buffer].filetype == "aviary_hawk" then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  vim.fn.delete(dir, "rf")
end

return M
