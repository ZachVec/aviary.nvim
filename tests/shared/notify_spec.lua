---@module 'luassert'

local Notify = require("aviary.shared.notify")

describe("aviary.shared.notify", function()
  local original_notify
  local notifications

  before_each(function()
    original_notify = vim.notify
    notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level, opts)
      notifications[#notifications + 1] = { msg = msg, level = level, opts = opts, fast = vim.in_fast_event() }
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("reports errors synchronously with the aviary title and unchanged message", function()
    Notify.error("failed")
    assert.are.same({
      { msg = "failed", level = vim.log.levels.ERROR, opts = { title = "aviary" }, fast = false },
    }, notifications)
  end)

  it("reports information and warnings at their levels with the aviary title", function()
    Notify.info("outlet: clipboard")
    Notify.warn("file is no longer available")
    assert.are.same({
      { msg = "outlet: clipboard", level = vim.log.levels.INFO, opts = { title = "aviary" }, fast = false },
      { msg = "file is no longer available", level = vim.log.levels.WARN, opts = { title = "aviary" }, fast = false },
    }, notifications)
  end)
end)
