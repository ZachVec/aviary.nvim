--- Pigeon owns tool definitions, Terminal options and action bindings; setup
--- acquires no resources. Setup rebuilds from defaults, rejects unknown
--- structural fields and preserves current options on failure. It validates
--- configuration data without checking executable availability, versions,
--- runtime context or key conflicts. Key sets replace defaults; actions merge
--- over built-ins. Default formatting uses plain paths and :L ranges; Claude
--- uses @ mentions, #L ranges and quotes unusual paths.

---@class aviary.pigeon.Tool
---@field command string[] nonempty argv, passed directly to the backend at creation
---@field format? aviary.shared.message.Format local override; nil uses Config.format at each send

---@alias aviary.pigeon.Actions table<string, fun(terminal: aviary.pigeon.Terminal)> action name to handler
---@alias aviary.pigeon.Keymaps table<string, string[]> action name to complete key set; empty disables

---@class aviary.pigeon.ViewConfig
---@field width number fraction of editor columns in (0, 1], or integer cells > 1
---@field height number fraction of editor lines in (0, 1], or integer cells > 1
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"

---@class aviary.pigeon.Config
---@field backend aviary.pigeon.BackendName
---@field format aviary.shared.message.Format default for tools without an override
---@field tools table<string, aviary.pigeon.Tool>
---@field keymaps aviary.pigeon.Keymaps mappings installed in the Terminal buffer
---@field actions aviary.pigeon.Actions handlers called with the Terminal by those mappings
---@field view aviary.pigeon.ViewConfig

---@class aviary.pigeon.ConfigOverrides
---@field backend? aviary.pigeon.BackendName
---@field format? aviary.shared.message.Format
---@field tools? table<string, aviary.pigeon.ToolOverrides> built-ins may be partially overridden; custom tools require command
---@field keymaps? aviary.pigeon.Keymaps each action's key set replaces its defaults; {} disables it
---@field actions? aviary.pigeon.Actions built-in overrides and user-defined handlers
---@field view? aviary.pigeon.ViewConfigOverrides

---@class aviary.pigeon.ToolOverrides
---@field command? string[]
---@field format? aviary.shared.message.Format

---@class aviary.pigeon.ViewConfigOverrides
---@field width? number
---@field height? number
---@field border? "none"|"single"|"double"|"rounded"|"solid"|"shadow"

--- Config() returns borrowed, read-only running options.
---@class aviary.pigeon.ConfigModule
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string? validation failure leaves previous options unchanged
---@operator call:aviary.pigeon.Config
local M = {}

---@type aviary.pigeon.Config
local defaults = {
  backend = "tmux",
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
  view = { width = 0.9, height = 0.9, border = "rounded" },
  keymaps = {
    close = { "<C-.>" },
  },
  actions = {
    close = function()
      vim.api.nvim_win_close(0, true)
    end,
  },
}
local options = vim.deepcopy(defaults)

---@type fun(value: any): boolean
local function dimension(value)
  return type(value) == "number" and value > 0 and value < math.huge and (value <= 1 or value % 1 == 0)
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
  if type(candidate.keymaps) ~= "table" or type(candidate.actions) ~= "table" then
    return false, "pigeon: keymaps and actions must be tables"
  end
  -- Deep merge extends arrays; key sets instead replace their defaults.
  for action, keys in pairs(opts and opts.keymaps or {}) do
    candidate.keymaps[action] = vim.deepcopy(keys)
  end
  for action, keys in pairs(candidate.keymaps) do
    if type(action) ~= "string" or type(keys) ~= "table" or not vim.islist(keys) then
      return false, "pigeon: keymaps must map actions to lists of keys"
    end
    for _, key in ipairs(keys) do
      if type(key) ~= "string" or key == "" or key:find("[%z\r\n]") then
        return false, "pigeon: keymaps." .. action .. " must contain nonempty Neovim keys"
      end
    end
    if type(candidate.actions[action]) ~= "function" then
      return false, "pigeon: no handler for " .. action
    end
  end
  for action, handler in pairs(candidate.actions) do
    if type(action) ~= "string" or type(handler) ~= "function" then
      return false, "pigeon: actions must map names to functions"
    end
  end
  if candidate.backend ~= "tmux" then
    return false, "pigeon: backend must be 'tmux'"
  end
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
  if type(candidate.view) ~= "table" then
    return false, "pigeon: view must be a table"
  end
  for key in pairs(candidate.view) do
    if defaults.view[key] == nil then
      return false, "pigeon: unknown option view." .. tostring(key)
    end
  end
  local view = candidate.view
  if not dimension(view.width) or not dimension(view.height) then
    return false, "pigeon: view width/height must be fractions in (0, 1] or integer cells > 1"
  end
  if not vim.tbl_contains({ "none", "single", "double", "rounded", "solid", "shadow" }, view.border) then
    return false, "pigeon: view.border must be a supported Neovim border name"
  end
  options = candidate
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
