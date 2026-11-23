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

---@type aviary.hawk.config.Config
local defaults = {
  keymaps = {
    close = { "q" },
    hawk = { "<CR>" },
    refresh = { "r" },
    toggle_check = { "x" },
  },
  actions = {
    close = function(tab)
      tab:close()
    end,
    hawk = function(tab)
      local row, lnum = tab:current()
      if row.kind == "diff" then
        ---@cast row aviary.hawk.snapshot.row.DiffRow
        row:jump(tab)
        return
      end
      ---@cast row aviary.hawk.snapshot.row.MetaRow
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
    end,
    refresh = function(tab)
      tab:refresh()
    end,
    toggle_check = function(tab)
      local row, lnum = tab:current()
      if row.kind == "diff" then
        ---@cast row aviary.hawk.snapshot.row.DiffRow
        row:toggle_check()
        tab:render(lnum - 1, lnum)
      end
    end,
  },
}
local options = vim.deepcopy(defaults)

---@param opts? aviary.hawk.config.Options
---@return boolean ok
---@return string? message validation failure; previous options remain unchanged
function M.setup(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return false, "hawk: options must be a table"
  end
  for key in pairs(opts) do
    if defaults[key] == nil then
      return false, "hawk: unknown option " .. tostring(key)
    end
  end
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if type(cfg.keymaps) ~= "table" or type(cfg.actions) ~= "table" then
    return false, "hawk: keymaps and actions must be tables"
  end
  -- Deep merge extends arrays; key sets instead replace their defaults.
  for action, keys in pairs(opts.keymaps or {}) do
    cfg.keymaps[action] = vim.deepcopy(keys)
  end
  for action, keys in pairs(cfg.keymaps) do
    if type(action) ~= "string" or type(keys) ~= "table" or not vim.islist(keys) then
      return false, "hawk: keymaps must map actions to lists of keys"
    end
    for _, key in ipairs(keys) do
      if type(key) ~= "string" or key == "" then
        return false, "hawk: keys must be non-empty strings"
      end
    end
    if type(cfg.actions[action]) ~= "function" then
      return false, "hawk: no handler for " .. action
    end
  end
  for action, handler in pairs(cfg.actions) do
    if type(action) ~= "string" or type(handler) ~= "function" then
      return false, "hawk: actions must map names to functions"
    end
  end
  options = cfg
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
