--- Weaver defaults and option validation.
local Message = require("aviary.shared.message")

---@alias aviary.weaver.Resolver fun(selection: aviary.weaver.Selection): aviary.shared.Message

---@class aviary.weaver.Config
---@field picker "snacks"|"fzf-lua" file/buffer selection implementation
---@field prompts table<string, string> named prompt templates (name -> template)
---@field resolvers table<string, aviary.weaver.Resolver> placeholder names without braces; handlers borrow the captured Selection
---@field references { join: string } join separates selected file/buffer references

---@class aviary.weaver.ConfigOverrides
---@field picker? "snacks"|"fzf-lua"
---@field prompts? table<string, string> add named templates or replace matching built-ins; unmatched built-ins remain
---@field resolvers? table<string, aviary.weaver.Resolver> add handlers or override built-ins
---@field references? { join: string } override the reference separator

--- Config() returns borrowed, read-only options.
---@class aviary.weaver.ConfigModule
---@operator call:aviary.weaver.Config
local M = {}

---@type aviary.weaver.Config
local defaults = {
  picker = "snacks",
  prompts = {
    ["{file}"] = "{file} ",
    ["{line}"] = "{line} ",
  },
  resolvers = {
    file = function(selection)
      return Message.reference(selection.path)
    end,
    line = function(selection)
      return Message.reference(selection.path, selection.start_row, selection.end_row)
    end,
  },
  references = {
    join = "\n",
  },
}

---@type aviary.weaver.Config
local options = vim.deepcopy(defaults)

--- Rebuild from defaults and opts, rejecting unknown structural fields.
---@param opts? aviary.weaver.ConfigOverrides
---@return boolean ok
---@return string? message validation failure; previous options remain unchanged
function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return false, "weaver: options must be a table"
  end
  for key in pairs(opts or {}) do
    if defaults[key] == nil then
      return false, "weaver: unknown option " .. tostring(key)
    end
  end
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if candidate.picker ~= "snacks" and candidate.picker ~= "fzf-lua" then
    return false, "weaver: picker must be 'snacks' or 'fzf-lua'"
  end
  if type(candidate.prompts) ~= "table" then
    return false, "weaver: prompts must be a table"
  end
  for name, template in pairs(candidate.prompts) do
    if type(name) ~= "string" or type(template) ~= "string" then
      return false, "weaver: prompts must map names to string templates: " .. tostring(name)
    end
  end
  if type(candidate.resolvers) ~= "table" then
    return false, "weaver: resolvers must be a table"
  end
  for name, resolve in pairs(candidate.resolvers) do
    if type(name) ~= "string" or type(resolve) ~= "function" then
      return false, "weaver: resolvers must map names to functions: " .. tostring(name)
    end
  end
  if type(candidate.references) ~= "table" then
    return false, "weaver: references must be a table"
  end
  for key in pairs(candidate.references) do
    if defaults.references[key] == nil then
      return false, "weaver: unknown option references." .. tostring(key)
    end
  end
  if type(candidate.references.join) ~= "string" then
    return false, "weaver: references.join must be a string"
  end
  options = candidate
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
