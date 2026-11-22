--- Open independent Git Reviews and configure their actions.
local Async = require("aviary.shared.async")
local Config = require("aviary.hawk.config")
local Git = require("aviary.hawk.git")
local Notify = require("aviary.shared.notify")
local Path = require("aviary.shared.path")
local Resources = require("aviary.shared.resources")
local Snapshot = require("aviary.hawk.snapshot")
local transaction = require("aviary.shared.transaction")

---@class aviary.hawk
---@field show fun() open a new Review for global cwd's worktree; warn outside Git; creation errors propagate after rollback
---@field setup fun(opts?: aviary.hawk.config.Options): boolean, string? rebuild options from defaults and overrides
local M = {}

--- A Review tab owns its comparison, windows, buffers and pending reads.
--- Construction acquires the layout synchronously and rolls it back on failure.
--- The list buffer has one line per metadata row followed by the change rows.
---@class aviary.hawk.Tab
---@field close fun(self: self) End an open Review. Stop pending reads immediately and schedule native resource cleanup.
---@field current fun(self: self): aviary.hawk.snapshot.row.Row, integer Borrow the selected row and its one-based buffer line from an open Tab.
---@field refresh fun(self: self) Refresh the current comparison using its drafts and redraw the change list.
---@field render fun(self: self, first: integer, last: integer) Draw the current snapshot over a zero-based half-open line range. Use -1 for the end of the list.
---@field to fun(self: self, style: string) Switch to direct or merge, converting compatible drafts and clearing the change list. Re-selecting the current style has no effect.
---@field bufnr integer owned list buffer
---@field private snapshot aviary.hawk.snapshot.Snapshot
---@field tabpage integer stable Neovim tabpage handle
---@field private group integer lifecycle augroup ID
---@field private winnr integer
---@field old_win integer left preview window for the old version
---@field new_win integer right preview window for the new version
---@field old_buf integer buffer displayed in the left preview window
---@field new_buf integer buffer displayed in the right preview window
---@field private cancel_list? fun() latest list cancellation, safe after completion
---@field cancel_body? fun() latest preview cancellation, safe after completion
local Tab = {}
Tab.__index = Tab

local NS_LABEL = vim.api.nvim_create_namespace("aviary.hawk.tab.label")
local NS_VALUE = vim.api.nvim_create_namespace("aviary.hawk.tab.value")

function Tab:current()
  local lnum = vim.api.nvim_win_get_cursor(self.winnr)[1]
  return self.snapshot.rows[lnum], lnum
end

function Tab:render(first, last)
  local bufnr = self.bufnr
  local rows = self.snapshot.rows
  local last_row = last == -1 and #rows or last
  local lines, marks = {}, {}
  for lnum = first + 1, last_row do
    local rendered = rows[lnum]:render(NS_LABEL, NS_VALUE)
    local index = lnum - first
    lines[index], marks[index] = rendered.text, rendered.marks
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, NS_LABEL, first, last)
  vim.api.nvim_buf_clear_namespace(bufnr, NS_VALUE, first, last)
  vim.api.nvim_buf_set_lines(bufnr, first, last, true, lines)
  vim.bo[bufnr].modified, vim.bo[bufnr].modifiable = false, false
  for index, row_marks in ipairs(marks) do
    for _, mark in ipairs(row_marks) do
      vim.api.nvim_buf_set_extmark(bufnr, mark.namespace, first + index - 1, mark.column, mark.opts)
    end
  end
end

function Tab:refresh()
  local snapshot = self.snapshot
  local skipped = false
  local cancel = Async.run(function(ctx)
    local ok, err = xpcall(function()
      local first = snapshot:refresh(ctx)
      if first < 0 then
        skipped = true
        return
      end
      self:render(first, -1)
      vim.api.nvim_buf_set_name(self.bufnr, ("Review #%d: %s"):format(self.tabpage, snapshot.title))
    end, function(err)
      if getmetatable(err) == Git.Error then
        ---@cast err aviary.hawk.git.Error
        return err.message
      end
      return debug.traceback(tostring(err), 2)
    end)
    if not ok then
      Notify.error(tostring(err))
    end
  end)
  -- A missing draft returns synchronously, leaving any previous query in flight.
  if not skipped then
    if self.cancel_list then
      self.cancel_list()
    end
    self.cancel_list = cancel
  end
end

function Tab:to(style)
  local current = self.snapshot
  local snapshot = current:to(style)
  if snapshot == current then
    return
  end
  local cancel = self.cancel_list
  if cancel then
    self.cancel_list = nil
    cancel()
  end
  self.snapshot = snapshot
  self:render(0, -1)
  vim.api.nvim_buf_set_name(self.bufnr, ("Review #%d: %s"):format(self.tabpage, snapshot.title))
end

function Tab:close()
  vim.api.nvim_del_augroup_by_id(self.group)
  if self.cancel_list then
    self.cancel_list()
    self.cancel_list = nil
  end
  -- Queued input must not restart work before deferred native reclamation.
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_call(self.bufnr, function()
      vim.cmd("nmapclear <buffer>")
    end)
  end
  if vim.api.nvim_win_is_valid(self.winnr) then
    vim.wo[self.winnr].winfixbuf = false
  end
  if self.cancel_body then
    self.cancel_body()
  end
  for _, win in ipairs({ self.old_win, self.new_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winfixbuf = false
      vim.api.nvim_win_call(win, vim.cmd.diffoff)
    end
  end
  vim.schedule(function()
    for _, buf in ipairs({ self.bufnr, self.old_buf, self.new_buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    if vim.api.nvim_tabpage_is_valid(self.tabpage) then
      if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd.qall()
      else
        vim.cmd({
          cmd = "tabclose",
          args = { tostring(vim.api.nvim_tabpage_get_number(self.tabpage)) },
          mods = { hide = true },
        })
      end
    end
  end)
end

function M.show()
  local root, reason = Path.git()
  if not root then
    Notify.warn(assert(reason))
    return
  end
  transaction(function(txn)
    txn:acquire(vim.api.nvim_get_current_win, vim.api.nvim_set_current_win)
    local src = vim.api.nvim_get_current_buf()
    local tab = txn:acquire(Resources.tabpage())
    local lhs = vim.api.nvim_get_current_win()
    local rhs = txn:acquire(Resources.window(src, true, { split = "right", win = lhs, noautocmd = true }))
    vim.cmd("wincmd =")
    local bot = txn:acquire(Resources.window(src, true, { split = "below", win = -1, height = 10, noautocmd = true }))

    ---@type table<integer, integer>
    local bufnrs = {
      [lhs] = txn:acquire(Resources.buffer(false, true)),
      [rhs] = txn:acquire(Resources.buffer(false, true)),
      [bot] = txn:acquire(Resources.buffer(false, true)),
    }

    for winnr, bufnr in pairs(bufnrs) do
      vim.bo[bufnr].bufhidden = "wipe"
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].modeline = false
      vim.bo[bufnr].undolevels = -1
      vim.api.nvim_win_set_buf(winnr, bufnr)
      vim.wo[winnr].winfixbuf = true
      if winnr == bot then
        vim.api.nvim_buf_set_name(bufnr, ("Review #%d"):format(tab))
      else
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
        vim.api.nvim_win_call(winnr, vim.cmd.diffthis)
      end
    end

    local bufnr = bufnrs[bot]
    local snapshot = Snapshot.new(root, "direct")
    local group = txn:acquire(Resources.augroup("aviary.hawk.tab." .. bufnr))
    local self = setmetatable({
      snapshot = snapshot,
      tabpage = tab,
      group = group,
      bufnr = bufnr,
      winnr = bot,
      old_win = lhs,
      new_win = rhs,
      old_buf = bufnrs[lhs],
      new_buf = bufnrs[rhs],
    }, Tab)
    self:render(0, -1)
    vim.api.nvim_win_set_cursor(bot, { 1, 0 })
    -- FileType callbacks can inspect the initialized list.
    vim.bo[bufnr].filetype = "aviary_hawk"
    vim.bo[bufnr].modified, vim.bo[bufnr].modifiable = false, false

    local options = vim.wo[bot][0]
    options.number = false
    options.relativenumber = false
    options.signcolumn = "no"
    options.foldenable = false
    options.foldcolumn = "0"
    options.statuscolumn = ""
    options.virtualedit = "none"

    local cfg = Config()
    for action, keys in pairs(cfg.keymaps) do
      local handler = cfg.actions[action]
      for _, key in ipairs(keys) do
        vim.keymap.set("n", key, function()
          handler(self)
        end, { buffer = bufnr, silent = true })
      end
    end

    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = vim.tbl_map(tostring, vim.tbl_keys(bufnrs)),
      callback = function()
        self:close()
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      pattern = vim.tbl_map(function(buffer)
        return ("<buffer=%d>"):format(buffer)
      end, vim.tbl_values(bufnrs)),
      callback = function()
        self:close()
      end,
    })
    vim.api.nvim_set_current_win(bot)
    return nil
  end)
end

function M.setup(opts)
  return Config.setup(opts)
end

return M
