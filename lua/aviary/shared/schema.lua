--- Build independent configuration tables from trusted schema rules and user overrides.
--- Objects merge by key, arrays replace, and functions are retained by reference.
--- Objects apply rule defaults, enclosing defaults, then user overrides.
--- Every fixed field must have a value after applying defaults.
--- Constructors borrow their rules and default values read-only.
---@alias aviary.schema.Scalar "string"|"number"|"function"
---@alias aviary.schema.Path (string|number)[]

---@class aviary.schema.Rule
---@field kind aviary.schema.Scalar|"object"|"array"
---@field default? any
---@field fields? table<string, aviary.schema.Rule> fixed object fields
---@field child? aviary.schema.Rule dynamic object values or array elements
---@field min? integer array length lower bound

---@class aviary.schema.StringRule: aviary.schema.Rule
---@field kind "string"

---@class aviary.schema
local M = {}

---@param opts? { default?: string }
---@return aviary.schema.StringRule
function M.string(opts)
  return { kind = "string", default = opts and opts.default }
end

---@param opts? { default?: number }
---@return aviary.schema.Rule
function M.number(opts)
  return { kind = "number", default = opts and opts.default }
end

---@param opts? { default?: function }
---@return aviary.schema.Rule
function M.func(opts)
  return { kind = "function", default = opts and opts.default }
end

---@param item aviary.schema.Rule|aviary.schema.Scalar
---@param opts? { default?: any[], min?: integer } min is nonnegative and defaults to zero
---@return aviary.schema.Rule
function M.array(item, opts)
  return {
    kind = "array",
    child = type(item) == "string" and { kind = item } or item,
    default = opts and opts.default,
    min = opts and opts.min,
  }
end

--- Supply either fixed fields or one dynamic entry keyed by `Schema.string()`.
---@param rules table<string, aviary.schema.Rule>|table<aviary.schema.StringRule, aviary.schema.Rule>
---@param opts? { default?: table<string, any> }
---@return aviary.schema.Rule
function M.object(rules, opts)
  local key, child = next(rules)
  local default = opts and opts.default
  if type(key) == "table" then
    return { kind = "object", child = child, default = default }
  end
  ---@cast rules table<string, aviary.schema.Rule>
  return { kind = "object", fields = rules, default = default }
end

---@param rule? aviary.schema.Rule
---@param base any
---@param override any
---@return any
local function overlay(rule, base, override)
  if override == nil then
    return base
  end
  if rule == nil or rule.kind ~= "object" or type(base) ~= "table" or type(override) ~= "table" then
    return override
  end

  local merged = {}
  for key, value in pairs(base) do
    merged[key] = value
  end
  for key, value in pairs(override) do
    local field = rule.fields and rule.fields[key] or rule.child
    merged[key] = overlay(field, merged[key], value)
  end
  return merged
end

---@param segment string|number
---@param reason string
---@param path? aviary.schema.Path
---@return nil
---@return string
---@return aviary.schema.Path
local function at(segment, reason, path)
  path = path or {}
  path[#path + 1] = segment
  return nil, reason, path
end

---@param rule aviary.schema.Rule
---@param override any
---@return any value
---@return string? reason
---@return aviary.schema.Path? path from innermost to outermost field, on failure
local function resolve(rule, override)
  local value = overlay(rule, rule.default, override)
  if value == nil then
    return nil, "is required"
  end

  local kind = rule.kind
  if kind == "array" then
    if type(value) ~= "table" or not vim.islist(value) then
      return nil, "must be an array"
    end
    if rule.min and #value < rule.min then
      return nil, ("must have at least %d %s"):format(rule.min, rule.min == 1 and "item" or "items")
    end
    local result = {}
    for index, item in ipairs(value) do
      local resolved, reason, path = resolve(rule.child, item)
      if reason then
        return at(index, reason, path)
      end
      result[index] = resolved
    end
    return result
  end

  if kind == "object" then
    if type(value) ~= "table" then
      return nil, "must be a table"
    end
    local result = {}
    local fields = rule.fields
    if fields then
      for key in pairs(value) do
        if fields[key] == nil then
          return at(tostring(key), "unknown option")
        end
      end
      for key, field in pairs(fields) do
        local resolved, reason, path = resolve(field, rawget(value, key))
        if reason then
          return at(key, reason, path)
        end
        result[key] = resolved
      end
    else
      for key, item in pairs(value) do
        if type(key) ~= "string" then
          return nil, "must have string keys"
        end
        local resolved, reason, path = resolve(rule.child, item)
        if reason then
          return at(key, reason, path)
        end
        result[key] = resolved
      end
    end
    return result
  end

  if type(value) ~= kind then
    return nil, "must be a " .. kind
  end
  return value
end

--- Return the resolved value, or nil and the first validation error with its field path.
--- Overrides are borrowed for this call. The returned tables belong to the caller.
---@param rule aviary.schema.Rule
---@param overrides any
---@param owner string prefix for validation errors
---@return any value
---@return string? reason
function M.resolve(rule, overrides, owner)
  local value, reason, path = resolve(rule, overrides)
  if not reason then
    return value
  end
  local field = "options"
  if path then
    local parts = {}
    for index = #path, 1, -1 do
      local segment = path[index]
      if type(segment) == "number" then
        parts[#parts + 1] = ("[%d]"):format(segment)
      elseif segment:match("^[%a_][%w_]*$") then
        parts[#parts + 1] = #parts == 0 and segment or "." .. segment
      else
        parts[#parts + 1] = ("[%q]"):format(segment)
      end
    end
    field = table.concat(parts)
  end
  local message = reason == "unknown option" and reason .. " " .. field or field .. " " .. reason
  return nil, owner .. ": " .. message
end

return M
