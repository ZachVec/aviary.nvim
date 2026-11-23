local M = {}

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

---@param buf integer
---@return string[]
function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, true)
end

---@param condition fun(): boolean
function M.wait_for(condition)
  assert(vim.wait(5000, condition, 10), "Hawk operation did not complete")
end

---@param lhs string
function M.press(lhs)
  M.flush()
  local map = vim.fn.maparg(lhs, "n", false, true)
  assert(type(map.callback) == "function", "no callback for " .. lhs)
  map.callback()
end

---@param lnum integer
---@param value? string
function M.edit_input(lnum, value)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local input = vim.ui.input
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(_, confirm)
    confirm(value)
  end
  local ok, err = pcall(M.press, "<CR>")
  vim.ui.input = input
  assert(ok, err)
end

---@param lnum integer
---@param value? string
function M.select_input(lnum, value)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local select = vim.ui.select
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(_, _, confirm)
    confirm(value)
  end
  local ok, err = pcall(M.press, "<CR>")
  vim.ui.select = select
  assert(ok, err)
end

---@param lnum integer
---@return table opts options passed to vim.ui.input
function M.input_opts(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local input, opts = vim.ui.input, nil
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(options, confirm)
    opts = options
    confirm(nil)
  end
  local ok, err = pcall(M.press, "<CR>")
  vim.ui.input = input
  assert(ok, err)
  return assert(opts)
end

---@param lnum integer
---@return fun(item: string): string format_item
function M.select_format(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local select, format = vim.ui.select, nil
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(_, opts, confirm)
    format = opts.format_item
    confirm(nil)
  end
  local ok, err = pcall(M.press, "<CR>")
  vim.ui.select = select
  assert(ok, err)
  return assert(format)
end

---@return aviary.hawk.Tab, integer
function M.open()
  local config = require("aviary.hawk.config")
  local previous = config()
  local tab
  assert(config.setup({
    keymaps = vim.tbl_extend("force", previous.keymaps, { capture_tab = { "<F12>" } }),
    actions = vim.tbl_extend("force", previous.actions, {
      capture_tab = function(current)
        tab = current
      end,
    }),
  }))
  local ok, err = pcall(require("aviary").hawk.show)
  assert(config.setup({ keymaps = previous.keymaps, actions = previous.actions }))
  assert(ok, err)
  M.press("<F12>")
  return assert(tab), vim.api.nvim_get_current_win()
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
