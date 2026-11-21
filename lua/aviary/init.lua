--- Composition root: lazy public features and configuration.
--- Feature implementations are resolved only when configured or used.
--- Configuration failures raise; root setup applies slices in unspecified order.
---@class aviary
---@field [string] any lazily loaded public modules
local M = {}

--- Last applied overrides for modules configured through this root.
--- Empty slices mean defaults and keep those modules included in later resets.
---@type table<string, table>
M.config = {}

setmetatable(M, {
  __index = function(t, k)
    ---@diagnostic disable-next-line: no-unknown
    t[k] = require("aviary." .. k)
    return rawget(t, k)
  end,
})

--- Resolve public modules only; propagate errors from existing modules.
---@param name string
---@return table? module
local function resolve(name)
  local path = "aviary." .. name
  local ok, module = pcall(require, path)
  if ok then
    return module
  end
  if not tostring(module):find(("module '%s' not found"):format(path), 1, true) then
    error(module, 0)
  end
  return nil
end

--- Rebuild root-managed modules from defaults plus this call's overrides.
--- Previously configured modules omitted from opts receive {} to reset.
--- Modules never configured through root are left untouched.
--- Load and check all named setup functions before applying options.
--- Validation failures raise and leave that slice unchanged; earlier successes
--- remain applied. Processing order is unspecified; there is no batch rollback.
---@param opts? table
---@return table
function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("aviary: options must be a table", 0)
  end
  local candidate = vim.deepcopy(opts or {})
  for name in pairs(M.config) do
    if candidate[name] == nil then
      candidate[name] = {}
    end
  end
  local modules = {}
  for name in pairs(candidate) do
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
      error(("aviary: %s is not a configurable module"):format(tostring(name)), 0)
    end
    local module = resolve(name)
    if type(module) ~= "table" or type(rawget(module, "setup")) ~= "function" then
      error(("aviary: %s is not a configurable module"):format(name), 0)
    end
    modules[name] = module
  end
  for name, module in pairs(modules) do
    local ok, message = module.setup(candidate[name])
    if not ok then
      error(message or ("aviary: invalid configuration for " .. name), 0)
    end
    M.config[name] = candidate[name]
  end
  return M
end

return M
