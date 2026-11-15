--- Compose tmux resources into Backend/Choice/Target behavior. This entry owns
--- receiver identity and formatting. CLI owns native fields and the display pane.
--- Receivers and displays live on the editor's existing server. Only marked
--- receivers participate in discovery; user sessions stay outside it.
--- Each show discovers/reuses the source's display; receivers outlive it.
--- Editor-exit cleanup is manual; no exit listener is registered.
--- Eval and send are separate fallible operations. Backends do not report exceptions.
--- Sending empty text skips delivery.
local Cli = require("aviary.pigeon.backends.tmux.cli")
local Config = require("aviary.pigeon.config")
local Path = require("aviary.shared.path")

---@class aviary.pigeon.TmuxTarget: aviary.pigeon.Target, aviary.pigeon.Choice
---@field instance string hexadecimal creation timestamp and receiver's session name
---@field tool string local tool configuration key
---@field cwd string captured absolute agent launch directory
---@field __eq fun(self: aviary.pigeon.TmuxTarget, other: aviary.pigeon.TmuxTarget): boolean compare instance
---@field resolve fun(self: aviary.pigeon.TmuxTarget): aviary.pigeon.TmuxTarget
local Target = {}

---@class aviary.pigeon.tmux.ToolChoice: aviary.pigeon.Choice
---@field resolve fun(self: aviary.pigeon.tmux.ToolChoice): aviary.pigeon.TmuxTarget
---@field private tool string local tool configuration key
local ToolChoice = {}

---@class aviary.pigeon.backends.tmux: aviary.pigeon.Backend
---@field list fun(): table<integer, aviary.pigeon.TmuxTarget|aviary.pigeon.tmux.ToolChoice>
local M = {}

Target.__index, ToolChoice.__index = Target, ToolChoice

function Target:__eq(other)
  return self.instance == other.instance
end

function Target:__tostring()
  local instance = self.instance:gsub("^0+", "")
  return (" %s %s [%s]"):format(self.tool, Path.tilde(self.cwd), instance ~= "" and instance or "0")
end

function Target:resolve()
  return self
end

function Target:show()
  Cli.focus(self.instance)
end

function Target:eval(message)
  local config = Config()
  local tool = assert(config.tools[self.tool], "missing local tool definition: " .. self.tool)
  return (assert(message:eval({ cwd = self.cwd, format = tool.format or config.format })))
end

function Target:send(text)
  if text == "" then
    return
  end
  Cli.paste("=" .. self.instance .. ":", text)
end

function ToolChoice:__tostring()
  return " " .. self.tool
end

function ToolChoice:resolve()
  local tool = assert(Config().tools[self.tool], "missing local tool definition: " .. self.tool)
  -- Interactive timestamp collisions are accepted; tmux reports name conflicts.
  local target = setmetatable({
    instance = ("%024x"):format(vim.uv.hrtime()),
    tool = self.tool,
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }, Target)
  Cli.create(target.instance, target.tool, tool.command, target.cwd, {
    status = "off",
    prefix = "None",
    prefix2 = "None",
    ["destroy-unattached"] = "off",
    ["detach-on-destroy"] = "on",
    ["@pigeon_tool"] = self.tool,
  })
  return target
end

function M.list()
  local config = Config()
  local choices = {}
  for _, session in ipairs(Cli.list()) do
    local target = setmetatable({ instance = session.name, tool = session.tool, cwd = session.cwd }, Target)
    if config.tools[target.tool] then
      choices[#choices + 1] = target
    end
  end
  local tools = vim.tbl_keys(config.tools)
  table.sort(tools)
  for _, name in ipairs(tools) do
    choices[#choices + 1] = setmetatable({ tool = name }, ToolChoice)
  end
  return choices
end

return M
