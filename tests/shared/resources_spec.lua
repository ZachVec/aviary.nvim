---@module 'luassert'

local Resources = require("aviary.shared.resources")
local transaction = require("aviary.shared.transaction")

describe("Shared Neovim resource factories", function()
  local origin, source, tabs, windows, buffers, group

  before_each(function()
    origin, source = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    tabs, windows, buffers = vim.api.nvim_list_tabpages(), vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
    group = vim.api.nvim_create_augroup("aviary.shared.resources.spec", { clear = true })
  end)

  after_each(function()
    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_set_current_win(origin)
    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
      if not vim.tbl_contains(tabs, tabpage) then
        vim.cmd({
          cmd = "tabclose",
          args = { tostring(vim.api.nvim_tabpage_get_number(tabpage)) },
          bang = true,
          mods = { hide = true, noautocmd = true },
        })
      end
    end
    for _, winnr in ipairs(vim.api.nvim_list_wins()) do
      if not vim.tbl_contains(windows, winnr) then
        vim.api.nvim_win_close(winnr, true)
      end
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(buffers, bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.api.nvim_set_current_win(origin)
  end)

  it("creates acquisition and rollback pairs without allocating native resources", function()
    local create_buffer, wipe_buffer = Resources.buffer(false, true)
    local create_window, close_window = Resources.window(source, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 4,
      noautocmd = true,
    })
    local create_tabpage, close_tabpage = Resources.tabpage()
    local create_group, delete_group = Resources.augroup("aviary.shared.resources.lazy")
    assert.are.same({}, vim.fn.getcompletion("aviary.shared.resources.lazy", "augroup"))
    for _, callback in ipairs({
      create_buffer,
      wipe_buffer,
      create_window,
      close_window,
      create_tabpage,
      close_tabpage,
      create_group,
      delete_group,
    }) do
      assert.is_function(callback)
    end
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(windows, vim.api.nvim_list_wins())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("commits buffers with requested flags and a float with unchanged configuration", function()
    local opts = {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 4,
      border = "none",
      noautocmd = true,
    }
    local before = vim.deepcopy(opts)
    local owned = transaction(function(txn)
      local scratch = txn:acquire(Resources.buffer(false, true))
      local listed = txn:acquire(Resources.buffer(true, false))
      local win = txn:acquire(Resources.window(scratch, false, opts))
      return { scratch = scratch, listed = listed, win = win }
    end)
    assert.is_false(vim.bo[owned.scratch].buflisted)
    assert.are.equal("nofile", vim.bo[owned.scratch].buftype)
    assert.is_true(vim.bo[owned.listed].buflisted)
    assert.are.equal("", vim.bo[owned.listed].buftype)
    assert.are.equal(owned.scratch, vim.api.nvim_win_get_buf(owned.win))
    assert.are.equal("editor", vim.api.nvim_win_get_config(owned.win).relative)
    assert.are.equal(20, vim.api.nvim_win_get_width(owned.win))
    assert.are.equal(4, vim.api.nvim_win_get_height(owned.win))
    assert.are.equal(origin, vim.api.nvim_get_current_win())
    assert.are.same(before, opts)
  end)

  it("rolls back tabpages and splits without deleting borrowed sources or firing close events", function()
    local events = 0
    vim.api.nvim_create_autocmd({ "WinClosed", "TabClosed" }, {
      group = group,
      callback = function()
        events = events + 1
      end,
    })
    local cause = {}
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:on_rollback(function()
          vim.api.nvim_set_current_win(origin)
        end)
        txn:acquire(Resources.tabpage())
        assert.are.equal(source, vim.api.nvim_get_current_buf())
        txn:acquire(Resources.window(source, true, { split = "below", height = 5, noautocmd = true }))
        error(cause, 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(cause, reason)
    assert.are.equal(0, events)
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(windows, vim.api.nvim_list_wins())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.equal(origin, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_buf_is_valid(source))
  end)

  it("wipes owned buffers on failure without running wipe listeners", function()
    local events = 0
    local ok, reason = pcall(function()
      transaction(function(txn)
        local owned = txn:acquire(Resources.buffer(false, true))
        vim.api.nvim_create_autocmd("BufWipeout", {
          group = group,
          buffer = owned,
          callback = function()
            events = events + 1
          end,
        })
        error("failed", 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal("failed", reason)
    assert.are.equal(0, events)
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.is_true(vim.api.nvim_buf_is_valid(source))
  end)

  it("accepts windows and buffers already removed by native cascading cleanup", function()
    local cause = {}
    local ok, reason = pcall(function()
      transaction(function(txn)
        local buf = txn:acquire(Resources.buffer(false, true))
        vim.bo[buf].bufhidden = "wipe"
        local win = txn:acquire(Resources.window(buf, false, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 20,
          height = 4,
          noautocmd = true,
        }))
        vim.api.nvim_win_close(win, true)
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        error(cause, 0)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(cause, reason)
    assert.are.same(windows, vim.api.nvim_list_wins())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
  end)

  it("releases earlier acquisitions when native split creation fails", function()
    local height, minimum = vim.o.winheight, vim.o.winminheight
    vim.o.winheight = vim.o.lines
    vim.o.winminheight = math.floor(vim.o.lines / 2) + 1
    local ok, reason = pcall(function()
      transaction(function(txn)
        txn:on_rollback(function()
          vim.api.nvim_set_current_win(origin)
        end)
        txn:acquire(Resources.tabpage())
        local buf = txn:acquire(Resources.buffer(false, true))
        return txn:acquire(Resources.window(buf, true, { split = "below", height = 10, noautocmd = true }))
      end)
    end)
    vim.o.winminheight = minimum
    vim.o.winheight = height
    assert.is_false(ok)
    assert.matches("E36", tostring(reason))
    assert.are.same(tabs, vim.api.nvim_list_tabpages())
    assert.are.same(windows, vim.api.nvim_list_wins())
    assert.are.same(buffers, vim.api.nvim_list_bufs())
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)
end)
