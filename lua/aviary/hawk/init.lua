--- Hawk owns one reusable Review instance and the list rendering contracts.
local config = require("aviary.hawk.config")
local review = require("aviary.hawk.review")

---@class aviary.hawk
---@field show fun() open or focus Review; creation and focus errors propagate
---@field setup fun(opts?: aviary.hawk.Options): boolean, string? rebuild options from defaults and overrides
local M = {}

---@type aviary.hawk.review.Tab? cleared synchronously when Review closes
local current

--- Handlers borrow their active concrete Tab for the call and follow its user contract.
--- Capture the item before async work rather than retaining the Tab beyond the call.
---@alias aviary.hawk.Actions table<string, fun(tab: aviary.hawk.review.Tab)>
---@alias aviary.hawk.Keymaps table<string, string[]> action name to literal lhs lists

--- Highlight offsets address the final single-line text: zero-based byte columns,
--- with an exclusive end. A nil hl leaves that range's default appearance.
---@class aviary.hawk.Highlight
---@field start_col integer
---@field end_col integer
---@field hl? string existing highlight group; nil uses the default appearance

---@class aviary.hawk.RenderedItem
---@field text string single line without control characters
---@field highlights aviary.hawk.Highlight[] ranges in text; may be empty

--- Rendering is synchronous and side-effect free. Items own field widths,
--- sanitization, alignment and shortening; width counts available text-area cells.
--- Fixed fields and a flexible field's minimum placeholder may overflow width.
---@class aviary.hawk.Item
---@field render fun(self: aviary.hawk.Item, width: integer): aviary.hawk.RenderedItem non-negative width; render current fields without querying a window or reading external data

function M.show()
  if not current then
    current = review.create(function()
      current = nil
    end)
  end
  current:focus()
end

function M.setup(opts)
  return config.setup(opts)
end

return M
