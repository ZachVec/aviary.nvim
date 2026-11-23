--- A Snapshot owns the rows of a Review. The caller owns the refresh flow
--- and draws the updated rows.

---@class aviary.hawk.snapshot.Snapshot
---@field init fun(self: self): self Initialize a newly constructed instance and return it.
---@field to fun(self: self, mode: string) Reserved for future snapshot switching; currently raises a "not implemented" error.
---@field refresh fun(self: self, ctx: AsyncContext): integer Query and update rows and title using the current drafts. Returns the zero-based start of the change range or -1 if required inputs are empty. Raises on query failure.
---@field title string comparison title for the last successful refresh, or the initial title before any refresh
---@field protected root string absolute worktree root
---@field rows aviary.hawk.snapshot.row.Row[] metadata followed by results

---@class aviary.hawk.snapshot
---@field new fun(root: string): aviary.hawk.snapshot.Snapshot Construct the default diff snapshot for the given worktree root.
local M = {}

function M.new(root)
  local impl = require("aviary.hawk.snapshot.diff")
  return setmetatable({ root = root }, impl):init()
end

return M
