--- Config() returns borrowed, read-only options.
---@class aviary.hawk.ConfigModule
---@operator call:aviary.hawk.Config
local M = {}

---@class aviary.hawk.Options
---@field keymaps? aviary.hawk.Keymaps each action's key set replaces its defaults; {} disables it
---@field actions? aviary.hawk.Actions defaults, overrides and user-defined handlers

---@class aviary.hawk.Config
---@field keymaps aviary.hawk.Keymaps action name to complete key set
---@field actions aviary.hawk.Actions defaults, overrides and user-defined handlers

---@type aviary.hawk.Config
local defaults = {
  keymaps = {
    close = { "q" },
    refresh = { "r" },
    jump = { "<CR>" },
    base_ref = { "b" },
    base_commit = { "B" },
    target_ref = { "f" },
    target_commit = { "F" },
    toggle = { "t" },
  },
  actions = {
    close = function()
      vim.cmd.close()
    end,
    refresh = function(tab)
      tab:refresh()
    end,
    jump = function(tab)
      local item = tab:current()
      if item then
        tab:jump(item)
      end
    end,
    base_ref = function(tab)
      tab:pick("base", "ref")
    end,
    base_commit = function(tab)
      tab:pick("base", "commit")
    end,
    target_ref = function(tab)
      tab:pick("target", "ref")
    end,
    target_commit = function(tab)
      tab:pick("target", "commit")
    end,
    toggle = function(tab)
      tab:toggle()
    end,
  },
}
local options = vim.deepcopy(defaults)

---@param opts? aviary.hawk.Options
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
