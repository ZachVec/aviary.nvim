local Git = require("aviary.hawk.git")
local Row = require("aviary.hawk.snapshot.row")
local Snapshot = require("aviary.hawk.snapshot")

---@class aviary.hawk.snapshot.direct.DirectSnapshot: aviary.hawk.snapshot.Snapshot
---@field old_row aviary.hawk.snapshot.row.RevisionRow old draft row in rows
---@field new_row aviary.hawk.snapshot.row.RevisionRow new draft row in rows
local DirectSnapshot = {}
DirectSnapshot.__index = DirectSnapshot

function DirectSnapshot:init()
  self.title = ""
  self.old_row = Row.revision("← old: ", self.root)
  self.new_row = Row.revision("→ new: ", self.root)
  self.rows = { self.old_row, self.new_row }
  return self
end

function DirectSnapshot:to(style)
  if style == "direct" then
    return self
  end
  local next_snapshot = Snapshot.new(self.root, style)
  if style == "merge" then
    ---@cast next_snapshot aviary.hawk.snapshot.merge.MergeSnapshot
    next_snapshot.old_row.value = self.old_row.value
    next_snapshot.new_row.value = self.new_row.value
  end
  return next_snapshot
end

function DirectSnapshot:refresh(ctx)
  local old, new = self.old_row.value, self.new_row.value
  if old == "" or new == "" then
    return -1
  end
  local entries = Git.diff(ctx, self.root, old, new)
  ---@type aviary.hawk.snapshot.row.Row[]
  local rows = { self.old_row, self.new_row }
  local first = #rows
  for _, entry in ipairs(entries) do
    rows[#rows + 1] = Row.diff(entry)
  end
  self.rows = rows
  old = old:match("^%x+$") and old:sub(1, 7) or old
  new = new:match("^%x+$") and new:sub(1, 7) or new
  self.title = (" %s   %s"):format(old, new)
  return first
end

return DirectSnapshot
