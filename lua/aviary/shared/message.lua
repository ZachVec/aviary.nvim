--- Nodes hold captured source values; evaluation waits for target context.
--- Construct through this module; it owns no configuration or delivery state.
--- Messages are opaque; evaluate through :eval. Keep them and borrowed child lists
--- unchanged while evaluation is pending.
--- Each built-in node evaluates through Message:eval; no node reads source data again.
--- Constructors trust the annotated Lua inputs; evaluation checks formatter output.
---
--- ```lua
--- local Message = require("aviary.shared.message")
--- local captured = Message.join(" ", { Message.reference("/project/a.lua", 12), Message.text("check this") })
--- local text, reason = captured:eval({ cwd = "/project", format = function(path) return path end })
--- ```
local Path = require("aviary.shared.path")

---@alias aviary.shared.message.Format fun(path: string, start_row?: integer, end_row?: integer): string?

--- Supplied once by the destination for each evaluation. No source reads occur.
---@class aviary.shared.message.RenderCtx
---@field cwd? string nil keeps references absolute
---@field format aviary.shared.message.Format destination-provided reference policy

--- Common contract for built-in nodes; construct through this module.
--- Evaluation leaves the tree unchanged and returns complete text (including empty
--- text), or nil and a reason on failure. Formatter exceptions propagate to callers.
---@class aviary.shared.Message
---@field eval fun(self: self, ctx: aviary.shared.message.RenderCtx): string?, string?

--- A literal node without trimming or added whitespace.
---@class aviary.shared.message.Text: aviary.shared.Message
---@field eval fun(self: self, ctx: aviary.shared.message.RenderCtx): string, nil
---@field private text string may be empty
local Text = {}

--- A captured location; successful evaluation preserves the formatter's result verbatim.
---@class aviary.shared.message.Reference: aviary.shared.Message
---@field eval fun(self: self, ctx: aviary.shared.message.RenderCtx): string?, string?
---@field private path string captured absolute path, or empty for an unnamed source; no disk-existence requirement
---@field private start_row? integer 1-based, inclusive; nil means whole-file reference
---@field private end_row? integer 1-based, inclusive; only meaningful with start_row
local Reference = {}

--- A composite node; an empty child list evaluates to empty text.
---@class aviary.shared.message.Join: aviary.shared.Message
---@field eval fun(self: self, ctx: aviary.shared.message.RenderCtx): string?, string?
---@field private delimiter string separator used only between children
---@field private children aviary.shared.Message[] ordered, borrowed children; keep unchanged while evaluation is pending
local Join = {}

---@class aviary.shared.message
---@field text fun(text: string): aviary.shared.message.Text construct a literal node
---@field reference fun(path: string, start_row?: integer, end_row?: integer): aviary.shared.message.Reference construct a location; spelling waits for the target context
---@field join fun(delimiter: string, children: aviary.shared.Message[]): aviary.shared.message.Join construct a composite node
local M = {}

Text.__index = Text
Reference.__index = Reference
Join.__index = Join

function Text:eval(_ctx)
  return self.text, nil
end

function Reference:eval(ctx)
  if self.path == "" then
    return nil, "reference has no filename"
  end
  local path = Path.relpath(ctx.cwd, self.path)
  local text = ctx.format(path, self.start_row, self.end_row)
  if type(text) ~= "string" or text == "" then
    return nil, ("reference could not be formatted: %s"):format(self.path)
  end
  return text, nil
end

function Join:eval(ctx)
  local out = {}
  for _, child in ipairs(self.children) do
    local text, reason = child:eval(ctx)
    if text == nil then
      return nil, reason
    end
    out[#out + 1] = text
  end
  return table.concat(out, self.delimiter), nil
end

function M.text(text)
  return setmetatable({ text = text }, Text)
end

function M.reference(path, start_row, end_row)
  return setmetatable({ path = path, start_row = start_row, end_row = end_row }, Reference)
end

function M.join(delimiter, children)
  return setmetatable({ delimiter = delimiter, children = children }, Join)
end

return M
