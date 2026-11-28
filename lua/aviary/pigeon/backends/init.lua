--- Private synchronous backend contracts. Each backend supplies its own Choices
--- and Agents. Listing Choices defers Agent creation to materialize(). Calls
--- raise on failure; backends do not notify or replay.
--- Choice ids are stable and unique within one backend's Choice list; strings
--- are display only. An Agent's client handle belongs to its Terminal.
---@alias aviary.pigeon.BackendName "tmux"

---@class aviary.pigeon.Choice
---@field id fun(self: self): string stable identity within this backend; creation choices return their creation intent
---@field __tostring fun(self: self): string display label
---@field materialize fun(self: self): aviary.pigeon.Agent return the existing Agent or create a new one for this Choice. Creation failures roll back acquired resources.

--- An Agent is also a Choice and returns itself from materialize().
---@class aviary.pigeon.Agent: aviary.pigeon.Choice
---@field cwd string absolute launch working directory
---@field attach fun(self: self): string[] command that directly attaches one client to this Agent's session
---@field retarget fun(self: self, client: string) move an existing client to this Agent; raises on failure
---@field eval fun(self: self, reference: aviary.pigeon.Reference): string render the borrowed reference in this Agent's context; raises on failure
---@field send fun(self: self, text: string) deliver without focusing or submitting; empty text is ignored

--- list() orders Agents by launch cwd, followed by creation Choices. When given
--- the current Agent, it places that Agent first if listed, then other Agents
--- with the same cwd, then proceeds in cwd order.
---@class aviary.pigeon.Backend
---@field list fun(current?: aviary.pigeon.Agent): aviary.pigeon.Choice[]
---@field current fun(client: string): aviary.pigeon.Agent resolve the Agent displayed by client; raises when the client is not attached to a Pigeon Agent

---@class aviary.pigeon.Backends: aviary.pigeon.Backend
---@field checkhealth fun(name: aviary.pigeon.BackendName) run read-only backend diagnostics
local M = {}

function M.list(current)
  local name = require("aviary.pigeon.config")().backend
  return require("aviary.pigeon.backends." .. name).list(current)
end

function M.current(client)
  local name = require("aviary.pigeon.config")().backend
  return require("aviary.pigeon.backends." .. name).current(client)
end

function M.checkhealth(name)
  require("aviary.pigeon.backends." .. name .. ".health").check()
end

return M
