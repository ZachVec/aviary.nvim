--- Config() returns borrowed, read-only options.
---@class aviary.hawk.config
---@operator call:aviary.hawk.config.Config
local M = {}

--- Handlers borrow the firing Tab for the call. Input callbacks may retain it while the Tab is open.
---@alias aviary.hawk.config.Actions table<string, fun(tab: aviary.hawk.Tab)>
---@alias aviary.hawk.config.Keymaps table<string, string[]>

---@class aviary.hawk.config.Options
---@field keymaps? aviary.hawk.config.Keymaps each action's key set replaces its defaults; {} disables it
---@field actions? aviary.hawk.config.Actions defaults, overrides and user-defined handlers

---@class aviary.hawk.config.Config
---@field keymaps aviary.hawk.config.Keymaps action name to complete key set
---@field actions aviary.hawk.config.Actions defaults, overrides and user-defined handlers

local Schema = require("aviary.shared.schema")

---@type aviary.hawk.config.Actions
local actions = {}

function actions.close(tab)
  tab:close()
end

function actions.hawk(tab)
  local row, lnum = tab:current()
  if row.kind == "diff" then
    row:jump(tab)
    return
  end
  ---@param value? string
  local function confirm(value)
    if value ~= nil then
      row:edit(value)
      tab:render(lnum - 1, lnum)
    end
  end
  if row.input.kind == "choice" then
    vim.ui.select(row.input.choices, {
      format_item = function(item)
        return item == row.value and (item .. " [current]") or item
      end,
    }, confirm)
  else
    vim.ui.input({ default = row.value }, confirm)
  end
end

function actions.refresh(tab)
  tab:refresh()
end

function actions.toggle_all(tab)
  local rows, all = {}, true
  for _, row in tab:changes() do
    rows[#rows + 1] = row
    all = all and row.checked
  end
  if #rows == 0 then
    return
  end
  for _, row in ipairs(rows) do
    if row.checked == all then
      row:toggle_check()
    end
  end
  tab:render(0, -1)
end

function actions.toggle_check(tab)
  local row, lnum = tab:current()
  if row.kind == "diff" then
    row:toggle_check()
    tab:render(lnum - 1, lnum)
  end
end

-- stylua: ignore
local schema = Schema.object({
  keymaps = Schema.object({ [Schema.string()] = Schema.array("string") }, {
    default = {
      close = { "q" },
      hawk = { "<CR>" },
      refresh = { "r" },
      toggle_all = { "X" },
      toggle_check = { "x" }
    }
  }),
  actions = Schema.object({ [Schema.string()] = Schema.func() }, { default = actions })
})

---@type aviary.hawk.config.Config
local options = assert(Schema.resolve(schema, {}, "hawk"))

---@param opts? aviary.hawk.config.Options
---@return boolean ok
---@return string? message validation failure leaves previous options unchanged
function M.setup(opts)
  local config, reason = Schema.resolve(schema, opts or {}, "hawk")
  if config == nil then
    return false, reason
  end
  options = config
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
