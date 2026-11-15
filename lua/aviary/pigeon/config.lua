--- Pigeon owns tool definitions and backend options; setup acquires no resources.
--- Setup rebuilds from defaults, rejects unknown structural fields and preserves
--- current options on failure. It validates configuration data without checking
--- executable availability, versions, runtime context or key conflicts.
--- Default formatting uses plain paths and :L ranges; Claude uses @ mentions,
--- #L ranges and quotes unusual paths.

---@class aviary.pigeon.Tool
---@field command string[] nonempty argv, passed directly to the backend at creation
---@field format? aviary.shared.message.Format local override; nil uses Config.format at each send

---@class aviary.pigeon.TmuxConfig
---@field width string tmux size including the border: positive integer cells or percentage
---@field height string tmux size including the border: positive integer cells or percentage
---@field close string tmux key that detaches only the floating view's client

---@class aviary.pigeon.Config
---@field format aviary.shared.message.Format default for clipboard and tools without an override
---@field tools table<string, aviary.pigeon.Tool>
---@field backend { default: aviary.pigeon.BackendName, tmux: aviary.pigeon.TmuxConfig }

---@class aviary.pigeon.ConfigOverrides
---@field format? aviary.shared.message.Format
---@field tools? table<string, aviary.pigeon.ToolOverrides> built-ins may be partially overridden; custom tools require command
---@field backend? { default?: aviary.pigeon.BackendName, tmux?: aviary.pigeon.TmuxConfigOverrides }

---@class aviary.pigeon.ToolOverrides
---@field command? string[]
---@field format? aviary.shared.message.Format

---@class aviary.pigeon.TmuxConfigOverrides
---@field width? string
---@field height? string
---@field close? string

--- Config() returns borrowed, read-only running options.
---@class aviary.pigeon.ConfigModule
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string? validation failure leaves previous options unchanged
---@field tmux_close_arg string read-only prepared tmux argument; raw key remains in Config().backend.tmux.close
---@operator call:aviary.pigeon.Config
local M = {}

---@type aviary.pigeon.Config
local defaults = {
  format = function(path, start_row, end_row)
    if not start_row then
      return path
    end
    local loc = (":L%d"):format(start_row)
    if end_row and end_row ~= start_row then
      loc = loc .. "-" .. end_row
    end
    return path .. " " .. loc
  end,
  tools = {
    codex = {
      command = { "codex" },
    },
    claude = {
      command = { "claude" },
      format = function(path, start_row, end_row)
        local mention = path:find("[^%w/_%.%-]") and ('"' .. path .. '"') or path
        local loc = start_row and ("#L%d"):format(start_row) or ""
        if start_row and end_row and end_row ~= start_row then
          loc = loc .. "-" .. end_row
        end
        return "@" .. mention .. loc
      end,
    },
  },
  backend = {
    default = "clipboard",
    tmux = { width = "90%", height = "90%", close = "C-." },
  },
}
local options = vim.deepcopy(defaults)
M.tmux_close_arg = options.backend.tmux.close

---@type fun(value: any): boolean
local function dimension(value)
  if type(value) ~= "string" then
    return false
  end
  local number = tonumber(value:match("^(%d+)%%?$"))
  return number ~= nil and number > 0 and number < math.huge
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return false, "pigeon: options must be a table"
  end
  for key in pairs(opts or {}) do
    if defaults[key] == nil then
      return false, "pigeon: unknown option " .. tostring(key)
    end
  end
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if type(candidate.format) ~= "function" then
    return false, "pigeon: format must be a function"
  end
  if type(candidate.tools) ~= "table" then
    return false, "pigeon: tools must be a table"
  end
  for name, tool in pairs(candidate.tools) do
    if type(name) ~= "string" or name == "" or type(tool) ~= "table" then
      return false, "pigeon: tools must map nonempty names to tool definitions"
    end
    for key in pairs(tool) do
      if key ~= "command" and key ~= "format" then
        return false, "pigeon: unknown option tools." .. name .. "." .. tostring(key)
      end
    end
    if type(tool.command) ~= "table" or not vim.islist(tool.command) or #tool.command == 0 then
      return false, "pigeon: tools." .. name .. ".command must be a nonempty argv list"
    end
    for _, arg in ipairs(tool.command) do
      if type(arg) ~= "string" or arg:find("\0", 1, true) then
        return false, "pigeon: tools." .. name .. ".command must contain strings without NUL"
      end
    end
    if tool.command[1] == "" then
      return false, "pigeon: tools." .. name .. ".command[1] must be nonempty"
    end
    if tool.format ~= nil and type(tool.format) ~= "function" then
      return false, "pigeon: tools." .. name .. ".format must be a function when provided"
    end
  end
  if type(candidate.backend) ~= "table" then
    return false, "pigeon: backend must be a table"
  end
  for key in pairs(candidate.backend) do
    if defaults.backend[key] == nil then
      return false, "pigeon: unknown option backend." .. tostring(key)
    end
  end
  if candidate.backend.default ~= "clipboard" and candidate.backend.default ~= "tmux" then
    return false, "pigeon: backend.default must be 'clipboard' or 'tmux'"
  end
  local tmux = candidate.backend.tmux
  if type(tmux) ~= "table" then
    return false, "pigeon: backend.tmux must be a table"
  end
  for key in pairs(tmux) do
    if defaults.backend.tmux[key] == nil then
      return false, "pigeon: unknown option backend.tmux." .. tostring(key)
    end
  end
  if not dimension(tmux.width) or not dimension(tmux.height) then
    return false, "pigeon: backend.tmux width/height must be positive integer strings, optionally followed by %"
  end
  if type(tmux.close) ~= "string" or tmux.close == "" or tmux.close:find("[%z\r\n]") then
    return false, "pigeon: backend.tmux.close must be a nonempty tmux key"
  end
  M.tmux_close_arg = (tmux.close:gsub(";$", "\\;"))
  options = candidate
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
