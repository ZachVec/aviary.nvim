--- Private synchronous backend contracts. Backends return complete data.
--- Choice strings are stable destination identities and display text.
--- An existing Choice and its resolved Target stringify identically. Creation
--- choices acquire nothing until synchronous resolve, which returns a complete
--- Target or raises after best-effort rollback. Eval returns complete text before
--- send writes it. Operation errors propagate; backends do not report them.
---@alias aviary.pigeon.BackendName "clipboard"|"tmux"

---@class aviary.pigeon.Target
---@field __tostring fun(self: aviary.pigeon.Target): string stable unique display string
---@field show fun(self: aviary.pigeon.Target) raise on execution failure
---@field eval fun(self: aviary.pigeon.Target, message: aviary.shared.Message): string evaluate completely; raise on failure
---@field send fun(self: aviary.pigeon.Target, text: string) write evaluated text; raise on failure

---@class aviary.pigeon.Choice
---@field __tostring fun(self: aviary.pigeon.Choice): string stable unique display string
---@field resolve fun(self: aviary.pigeon.Choice): aviary.pigeon.Target synchronous; no resource acquisition until selected

---@class aviary.pigeon.Backend
---@field list fun(): aviary.pigeon.Choice[] complete inventory, including supported tool creation choices
---@class aviary.pigeon.Backends
---@field get fun(name: aviary.pigeon.BackendName): aviary.pigeon.Backend
local M = {}

function M.get(name)
  return require("aviary.pigeon.backends." .. name)
end

return M
