--- Backend owns Agent creation/discovery and delivery on the host tmux server.
--- Each Agent has one persistent session with one marked window/pane; clients
--- attach directly to that session. Calls are synchronous and raise on failure.
--- No UI or notifications here.
local Cli = require("aviary.pigeon.backends.tmux.cli")
local Config = require("aviary.pigeon.config")
local Path = require("aviary.shared.path")

---@class aviary.pigeon.tmux.Agent: aviary.pigeon.Agent, aviary.pigeon.tmux.Record
---@field id fun(self: self): string return the persistent session name
---@field resolve fun(self: self): aviary.pigeon.tmux.Agent
---@field attach fun(self: self): string[] directly attach one client to this Agent session
---@field retarget fun(self: self, client: string) move the client to this Agent; raises on failure
---@field eval fun(self: self, message: aviary.shared.Message): string evaluate borrowed Message using this Agent's cwd and current local tool format; raises on failure
---@field send fun(self: self, text: string) paste without focusing or submitting; empty text is ignored
local Agent = {}
Agent.__index = Agent

---@class aviary.pigeon.tmux.ToolChoice: aviary.pigeon.Choice
---@field private tool string
---@field id fun(self: self): string return the creation intent id
---@field resolve fun(self: self): aviary.pigeon.tmux.Agent create a persistent Agent; editor cwd is captured at resolution
local ToolChoice = {}
ToolChoice.__index = ToolChoice

---@class aviary.pigeon.backends.tmux: aviary.pigeon.Backend
---@field list fun(): table<integer, aviary.pigeon.tmux.Agent|aviary.pigeon.tmux.ToolChoice> configured Agents, then sorted creation choices
local M = {}

function Agent:id()
  return self.session
end

function Agent:__tostring()
  return (" %s %s [%s]"):format(self.tool, Path.tilde(self.cwd), self.session)
end

function Agent:resolve()
  return self
end

function Agent:attach()
  return Cli.attach(self.session)
end

function Agent:retarget(client)
  Cli.retarget(client, self.session)
end

function Agent:eval(message)
  local config = Config()
  local tool = assert(config.tools[self.tool], "missing local tool definition: " .. self.tool)
  return (assert(message:eval({ cwd = self.cwd, format = tool.format or config.format })))
end

function Agent:send(text)
  if text ~= "" then
    Cli.paste(self.pane, text)
  end
end

function ToolChoice:id()
  return self.tool
end

function ToolChoice:__tostring()
  return " " .. self.tool
end

function ToolChoice:resolve()
  local tool = assert(Config().tools[self.tool], "missing local tool definition: " .. self.tool)
  return setmetatable(Cli.create(self.tool, tool.command, vim.fs.normalize(vim.fn.getcwd())), Agent) --[[@as aviary.pigeon.tmux.Agent]]
end

function M.list()
  ---@type table<integer, aviary.pigeon.tmux.Agent|aviary.pigeon.tmux.ToolChoice>
  local choices = {}
  local config = Config()
  for _, record in ipairs(Cli.list()) do
    if config.tools[record.tool] then
      choices[#choices + 1] = setmetatable(record, Agent) --[[@as aviary.pigeon.tmux.Agent]]
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
