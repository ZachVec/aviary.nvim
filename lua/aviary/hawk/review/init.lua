--- Review choices outlive the UI. Each instance owns its version buffers,
--- independent list/body reads and current Git watch. User AviaryReviewChanged
--- queues refreshes from comparison choices and Git observation. Creation completes
--- synchronously in one transaction and queues the first metadata read.
--- Owned window closure or buffer wipe ends the instance before on_close runs.
--- List/body work and observation stop, and window settings are released first.
--- Native resources are reclaimed later. The transaction never escapes creation.
--- Version filetype assignment does not trigger FileType events.
--- Titles abbreviate commit hashes without changing captured revisions.
--- List refreshes coalesce and cancel superseded reads; successful rendering commits
--- the ordered original Changes. Width-only redraws preserve the native view and
--- never start data reads. List and body cancellation remain independent.
local Async = require("aviary.shared.async")
local Config = require("aviary.hawk.config")
local Editor = require("aviary.shared.editor")
local Path = require("aviary.shared.path")
local Resources = require("aviary.shared.resources")
local Review = require("aviary.hawk.review.review")
local transaction = require("aviary.shared.transaction")

---@class aviary.hawk.review
---@field create fun(on_close: fun()): aviary.hawk.review.Tab complete instance or raises after rollback; owned window/buffer closure calls on_close once
local M = {}

---@class aviary.hawk.review.Snapshot
---@field name string list buffer title
---@field items aviary.hawk.Change[] ordered original Changes; keep the list unchanged while displayed

---@class aviary.hawk.review.Tab
---@field focus fun(self: self) select the active bottom window
---@field current fun(self: self): aviary.hawk.Change? original selected Change; nil before success or outside populated rows
---@field refresh fun(self: self) cancel superseded metadata work and request a coalesced refresh
---@field jump fun(self: self, item: aviary.hawk.Change) read captured versions and immediately focus the right window; completion never changes focus
---@field pick fun(self: self, side: "base"|"target", kind: "ref"|"commit") choose a session comparison endpoint without retaining the Tab in picker callbacks
---@field toggle fun(self: self) toggle direct/merge-base comparison and notify the active UI
---@field package redraw fun(self: self, snapshot: aviary.hawk.review.Snapshot, width: integer, force: boolean) draw at the supplied text-area width if forced or changed; preserve the native view
---@field private winnr integer owned list window
---@field private bufnr integer owned list buffer
---@field private old_win integer owned left version window
---@field private new_win integer owned right version window
---@field private old_buf integer owned left version buffer
---@field private new_buf integer owned right version buffer
---@field package cancel_list? fun() latest metadata cancellation, retained until replacement or closure; harmless after completion
---@field package cancel_body? fun() latest body cancellation, harmless after completion
---@field package snapshot? aviary.hawk.review.Snapshot latest successfully rendered Changes
---@field package scheduled boolean clearing this cancels a queued refresh
---@field private width integer last rendered text-area width
local ReviewTab = {}

---@type aviary.hawk.review.Context
local context = { target = "index", style = "direct" }

ReviewTab.__index = ReviewTab
local namespace = vim.api.nvim_create_namespace("aviary.hawk.review.list")

local function revision_label(revision)
  return revision:match("^%x+$") and revision:sub(1, 7) or revision
end

local function fill(buf, path, revision, text, kind)
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    table.remove(lines)
  end
  vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("delmarks!")
  end)
  vim.api.nvim_buf_set_name(buf, ("%s://%s"):format(revision_label(revision), path:gsub("%c", " ")))
  local ft = kind == "text" and (vim.filetype.match({ filename = path }) or "") or ""
  vim.api.nvim_buf_call(buf, function()
    -- Avoid FileType hooks attaching editing tools to readonly version buffers.
    vim.cmd({ cmd = "setlocal", args = { "filetype=" .. ft }, mods = { noautocmd = true } })
  end)
  vim.bo[buf].endofline = text:sub(-1) == "\n"
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
end

function ReviewTab:focus()
  vim.api.nvim_set_current_win(self.winnr)
end

function ReviewTab:current()
  return self.snapshot and self.snapshot.items[vim.api.nvim_win_get_cursor(self.winnr)[1]] or nil
end

function ReviewTab:refresh()
  if self.cancel_list then
    self.cancel_list()
  end
  if self.scheduled then
    return
  end
  self.scheduled = true
  vim.schedule(function()
    if not self.scheduled then
      return
    end
    self.scheduled = false
    self.cancel_list = Async.run(function(ctx)
      local selection = { root = Path.git(), base = context.base, target = context.target, style = context.style }
      local items, base = Review.read(ctx, selection)
      local snapshot = {
        name = base and ("Review: %s %s   %s"):format(
          selection.style == "direct" and "" or "󰓁",
          revision_label(base),
          revision_label(selection.target)
        ) or "Review",
        items = items,
      }
      self:redraw(snapshot, Editor.text_width(self.winnr, #items), true)
      self.snapshot = snapshot
    end)
  end)
end

function ReviewTab:redraw(snapshot, width, force)
  if not force and width == self.width then
    return
  end
  local saved = vim.api.nvim_win_call(self.winnr, vim.fn.winsaveview)
  local lines, spans = {}, {}
  for row, item in ipairs(snapshot.items) do
    local rendered = item:render(width)
    lines[row] = rendered.text
    for _, highlight in ipairs(rendered.highlights) do
      if highlight.hl and highlight.end_col > highlight.start_col then
        spans[#spans + 1] = {
          row = row - 1,
          start_col = highlight.start_col,
          end_col = highlight.end_col,
          hl = highlight.hl,
        }
      end
    end
  end
  vim.api.nvim_buf_set_name(self.bufnr, snapshot.name)
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.bo[self.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.bufnr, namespace, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(
      self.bufnr,
      namespace,
      span.row,
      span.start_col,
      { end_col = span.end_col, hl_group = span.hl }
    )
  end
  vim.api.nvim_win_call(self.winnr, function()
    vim.fn.winrestview(saved)
  end)
  self.width = width
end

function ReviewTab:jump(item)
  if self.cancel_body then
    self.cancel_body()
  end
  vim.api.nvim_set_current_win(self.new_win)
  self.cancel_body = Async.run(function(ctx)
    local text = Review.text(ctx, item)
    -- Release both names before filling so the sides can exchange preview names.
    vim.api.nvim_buf_set_name(self.old_buf, "")
    vim.api.nvim_buf_set_name(self.new_buf, "")
    fill(self.old_buf, item.old_path or item.path, item.base, text.old, item.kind)
    fill(self.new_buf, item.path, item.target, text.new, item.kind)
    for _, win in ipairs({ self.old_win, self.new_win }) do
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
    vim.api.nvim_win_call(self.new_win, function()
      vim.cmd("diffupdate")
    end)
  end)
end

function ReviewTab:pick(side, kind)
  Async.run(function(ctx)
    local root = assert(Path.git())
    local choices = Review.choices(ctx, root, kind, side == "target" and kind == "ref")
    if Path.git() ~= root then
      return
    end
    vim.ui.select(choices, {
      prompt = "Review " .. side .. " " .. kind .. ": ",
      format_item = function(choice)
        return choice.label
      end,
    }, function(choice)
      if not choice or Path.git() ~= root then
        return
      end
      if side == "base" then
        context.base = choice.revision
      else
        context.target = choice.revision
      end
      vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
    end)
  end)
end

function ReviewTab:toggle()
  context.style = context.style == "direct" and "merge_base" or "direct"
  vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
end

function M.create(on_close)
  return transaction(function(txn)
    local origin, source = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    txn:on_rollback(function()
      vim.api.nvim_set_current_win(origin)
    end)
    local tabpage = txn:acquire(Resources.tabpage())
    local old_win = vim.api.nvim_get_current_win()
    local new_win = txn:acquire(Resources.window(source, true, { split = "right", win = old_win, noautocmd = true }))
    vim.cmd("wincmd =")
    local bottom_win = txn:acquire(Resources.window(source, true, {
      split = "below",
      win = -1,
      height = 10,
      noautocmd = true,
    }))
    local bufnr = txn:acquire(Resources.buffer(false, true))
    local old_buf = txn:acquire(Resources.buffer(false, true))
    local new_buf = txn:acquire(Resources.buffer(false, true))
    local body = { old_win, new_win }
    for index, win in ipairs(body) do
      local buf = index == 1 and old_buf or new_buf
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false
      vim.bo[buf].modeline = false
      vim.bo[buf].undolevels = -1
      vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].winfixbuf = true
      vim.api.nvim_win_call(win, vim.cmd.diffthis)
    end
    local self = setmetatable({
      bufnr = bufnr,
      winnr = bottom_win,
      width = 0,
      scheduled = false,
      old_win = old_win,
      new_win = new_win,
      old_buf = old_buf,
      new_buf = new_buf,
    }, ReviewTab)
    local group = txn:acquire(Resources.augroup("aviary.hawk.review.tab." .. bufnr))
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modeline = false
    vim.bo[bufnr].undolevels = -1
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_win_set_buf(bottom_win, bufnr)
    vim.wo[bottom_win].winfixbuf = true
    vim.bo[bufnr].filetype = "aviary_hawk"
    local function redraw()
      if self.snapshot and vim.api.nvim_win_is_valid(bottom_win) then
        self:redraw(self.snapshot, Editor.text_width(bottom_win), false)
      end
    end
    vim.api.nvim_create_autocmd("WinResized", { group = group, callback = redraw })
    vim.api.nvim_create_autocmd("OptionSet", {
      group = group,
      pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "statuscolumn" },
      callback = redraw,
    })
    local function detach()
      self.scheduled = false
      if self.cancel_list then
        self.cancel_list()
        self.cancel_list = nil
      end
      self.snapshot = nil
      -- Queued input must not restart work before deferred native reclamation.
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("nmapclear <buffer>")
        end)
      end
      if vim.api.nvim_win_is_valid(bottom_win) then
        vim.wo[bottom_win].winfixbuf = false
      end
    end
    txn:on_rollback(detach)
    local cfg = Config()
    for action, keys in pairs(cfg.keymaps) do
      local handler = cfg.actions[action]
      for _, lhs in ipairs(keys) do
        vim.keymap.set("n", lhs, function()
          handler(self)
        end, { buffer = bufnr, silent = true })
      end
    end

    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AviaryReviewChanged",
      callback = function()
        self:refresh()
      end,
    })
    local stop = Review.start()
    txn:on_rollback(stop)

    local function close()
      vim.api.nvim_del_augroup_by_id(group)
      stop()
      detach()
      if self.cancel_body then
        self.cancel_body()
      end
      for _, win in ipairs(body) do
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].winfixbuf = false
          vim.api.nvim_win_call(win, vim.cmd.diffoff)
        end
      end
      on_close()
      vim.schedule(function()
        for _, buf in ipairs({ bufnr, old_buf, new_buf }) do
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end
        if vim.api.nvim_tabpage_is_valid(tabpage) then
          if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd.qall()
          else
            vim.cmd({
              cmd = "tabclose",
              args = { tostring(vim.api.nvim_tabpage_get_number(tabpage)) },
              mods = { hide = true },
            })
          end
        end
      end)
    end
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = { tostring(bottom_win), tostring(old_win), tostring(new_win) },
      callback = close,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      pattern = {
        ("<buffer=%d>"):format(bufnr),
        ("<buffer=%d>"):format(old_buf),
        ("<buffer=%d>"):format(new_buf),
      },
      callback = close,
    })
    self:refresh()
    return self
  end)
end

return M
