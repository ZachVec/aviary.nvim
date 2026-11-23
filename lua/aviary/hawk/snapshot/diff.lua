local Git = require("aviary.hawk.git")
local Row = require("aviary.hawk.snapshot.row")

---@class aviary.hawk.snapshot.diff.DiffSnapshot: aviary.hawk.snapshot.Snapshot
---@field old_row aviary.hawk.snapshot.row.RevisionRow old draft row in rows
---@field new_row aviary.hawk.snapshot.row.RevisionRow new draft row in rows
---@field style_row aviary.hawk.snapshot.row.MetaRow style draft row in rows
local DiffSnapshot = {}
DiffSnapshot.__index = DiffSnapshot

function DiffSnapshot:init()
  self.title = ""
  self.old_row = Row.revision("┌ old: ", self.root)
  self.new_row = Row.revision("└ new: ", self.root)
  self.style_row = Row.choice(" style: ", { "direct", "merge-base" }, "direct")
  self.rows = { self.style_row, self.old_row, self.new_row }
  return self
end

---@param _ string requested mode; reserved until snapshot switching is implemented
function DiffSnapshot:to(_)
  error("aviary.hawk: snapshot switching is not implemented", 0)
end

function DiffSnapshot:refresh(ctx)
  local style = self.style_row.value
  local old, new = self.old_row.value, self.new_row.value
  if style == "" or old == "" or new == "" then
    return -1
  end
  local entries = Git.diff(ctx, self.root, old, new, style == "merge-base")
  ---@type aviary.hawk.snapshot.row.Row[]
  local rows = { self.style_row, self.old_row, self.new_row }
  local first = #rows
  for _, entry in ipairs(entries) do
    rows[#rows + 1] = Row.diff(entry)
  end
  self.rows = rows
  old = old:match("^%x+$") and old:sub(1, 7) or old
  new = new:match("^%x+$") and new:sub(1, 7) or new
  self.title = ("%s   %s"):format(old, new)
  return first
end

return DiffSnapshot
