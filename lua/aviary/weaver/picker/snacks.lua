--- Use Snacks' built-in file and buffer sources and previews.
local M = {}
M.requires = "snacks"

---@class aviary.weaver.picker.SnacksItem
---@field buf? integer
---@field file? string
---@field cwd? string

---@class aviary.weaver.picker.SnacksPicker
---@field selected fun(self: aviary.weaver.picker.SnacksPicker, opts: {fallback: boolean}): aviary.weaver.picker.SnacksItem[]
---@field close fun(self: aviary.weaver.picker.SnacksPicker)

---@param source aviary.weaver.picker.Source
---@param cwd string captured global cwd
---@param on_confirm fun(paths: string[])
---@param opts aviary.weaver.picker.AdapterOpts
function M.pick(source, cwd, on_confirm, opts)
  local picker = require("snacks").picker
  local picker_opts = {
    ---@param selected aviary.weaver.picker.SnacksPicker
    confirm = function(selected)
      local paths = {}
      for _, item in ipairs(selected:selected({ fallback = true })) do
        local path = picker.util.path(item)
        if path then
          paths[#paths + 1] = path
        end
      end
      -- Snacks defers part of its close cleanup.
      selected:close()
      vim.schedule(function()
        on_confirm(paths)
      end)
    end,
  }
  local filter = opts.filter
  if source == "files" then
    picker_opts.cwd, picker_opts.follow = cwd, true
  elseif filter then
    picker_opts.filter = {
      ---@param item aviary.weaver.picker.SnacksItem
      filter = function(item)
        local buf = item.buf
        return buf ~= nil and filter(buf)
      end,
    }
  end
  picker.pick(source, picker_opts)
end

return M
