--- Native Neovim resource factories. Each returns an acquisition
--- function and its rollback callback; creating the pair acquires no resources.
--- Factories complete synchronously and raise on acquisition failure. Window
--- configurations are borrowed read-only until acquisition completes.
---
--- Tabpages split the current buffer into a new tab. Windows borrow their display
--- buffer; only buffer rollback owns buffer deletion. Rollback suppresses native
--- autocommands and tolerates resources already removed by native cleanup.
--- Features own window arrangement, configuration and successful lifetime closure.
---
--- ```lua
--- local Resources = require("aviary.shared.resources")
--- local buf = txn:acquire(Resources.buffer(false, true))
--- local win = txn:acquire(Resources.window(buf, true, opts))
--- ```

---@class aviary.shared.resources
---@field buffer fun(listed: boolean, scratch: boolean): ((fun(): integer), fun(bufnr: integer))
---@field window fun(bufnr: integer, enter: boolean, opts: vim.api.keyset.win_config): ((fun(): integer), fun(winnr: integer))
---@field tabpage fun(): ((fun(): integer), fun(tabpage: integer))
---@field augroup fun(name: string): ((fun(): integer), fun(group: integer)) callers must not share a name between live acquisitions; acquiring clears prior callbacks
local M = {}

function M.buffer(listed, scratch)
  return function()
    return vim.api.nvim_create_buf(listed, scratch)
  end, function(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.cmd({ cmd = "bwipeout", args = { tostring(bufnr) }, bang = true, mods = { noautocmd = true } })
    end
  end
end

function M.window(bufnr, enter, opts)
  return function()
    return vim.api.nvim_open_win(bufnr, enter, opts)
  end, function(winnr)
    vim.fn.win_execute(winnr, "noautocmd hide close")
  end
end

function M.tabpage()
  return function()
    vim.cmd("noautocmd tab split")
    return vim.api.nvim_get_current_tabpage()
  end, function(tabpage)
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.cmd({
        cmd = "tabclose",
        args = { tostring(vim.api.nvim_tabpage_get_number(tabpage)) },
        mods = { hide = true, noautocmd = true },
      })
    end
  end
end

function M.augroup(name)
  return function()
    return vim.api.nvim_create_augroup(name, { clear = true })
  end, vim.api.nvim_del_augroup_by_id
end

return M
