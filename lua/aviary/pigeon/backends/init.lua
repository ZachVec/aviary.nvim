--- Private synchronous backend contracts. Each backend supplies its own Choices
--- and Agents. No resources are acquired until a Choice resolves or an Agent
--- attaches. Calls raise on failure; backends do not notify or replay.
--- Choice ids are stable and unique within one backend's Choice list; strings
--- are display only. An Agent's client handle belongs to its Terminal.
---@alias aviary.pigeon.BackendName "tmux"

---@class aviary.pigeon.Choice
---@field id fun(self: self): string stable identity within this backend; creation choices return their creation intent
---@field __tostring fun(self: self): string display label
---@field resolve fun(self: self): aviary.pigeon.Agent resolve synchronously; creation failures roll back acquired resources

--- An Agent is also a Choice: it is an existing selectable target and resolves
--- to itself. Creation intents remain Choice-only implementations.
---@class aviary.pigeon.Agent: aviary.pigeon.Choice
---@field attach fun(self: self): string[] command that directly attaches one client to this Agent's session
---@field retarget fun(self: self, client: string) move an existing client to this Agent; raises on failure
---@field eval fun(self: self, reference: aviary.pigeon.Reference): string render the borrowed reference in this Agent's context; raises on failure
---@field send fun(self: self, text: string) deliver without focusing or submitting; empty text is ignored

---@class aviary.pigeon.Backend
---@field list fun(): aviary.pigeon.Choice[] current inventory, including supported tool creation choices
---@field current fun(client: string): aviary.pigeon.Agent resolve the Agent displayed by client; raises when the client is not attached to a Pigeon Agent

---@class aviary.pigeon.Backends
---@field list fun(): aviary.pigeon.Choice[] current inventory from the configured backend
---@field current fun(client: string): aviary.pigeon.Agent resolve the Agent displayed by client from the configured backend
---@field checkhealth fun(name: aviary.pigeon.BackendName) run read-only backend diagnostics
local M = {}

function M.list()
  local name = require("aviary.pigeon.config")().backend
  return require("aviary.pigeon.backends." .. name).list()
end

function M.current(client)
  local name = require("aviary.pigeon.config")().backend
  return require("aviary.pigeon.backends." .. name).current(client)
end

function M.checkhealth(name)
  require("aviary.pigeon.backends." .. name .. ".health").check()
end

return M
