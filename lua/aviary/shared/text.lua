--- Display-cell padding and shortening for single-line text.
--- padding adds spaces to a nonnegative minimum width, never truncating the text.
--- Width follows Neovim's current display settings. Returned offsets use bytes
--- so callers can highlight the original text without including padding.
--- truncate uses a nonnegative display-cell budget, retaining a whole base
--- character and its composing characters together. The ellipsis is the minimum
--- result for overflowing text, even when width cannot fit it. Middle shortening
--- gives the suffix the odd cell. Inputs are single-line without control characters.
---@class aviary.shared.text
---@field padding fun(text: string, align: "left"|"right", length: integer): string, integer, integer padded text, zero-based byte start and original byte length
---@field truncate fun(text: string, mode: "end"|"middle", width: integer): string unchanged when it fits, otherwise shortened with an ellipsis
local M = {}

function M.padding(text, align, length)
  local padding = string.rep(" ", math.max(0, length - vim.fn.strdisplaywidth(text)))
  if align == "right" then
    return padding .. text, #padding, #text
  end
  return text .. padding, 0, #text
end

function M.truncate(text, mode, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local budget = math.max(0, width - vim.fn.strdisplaywidth(ellipsis))
  local count = vim.fn.strchars(text, true)
  ---@type fun(limit: integer, tail: boolean): string
  local function take(limit, tail)
    local result, used = "", 0
    for offset = 0, count - 1 do
      local char = vim.fn.strcharpart(text, tail and count - offset - 1 or offset, 1, true)
      local cells = vim.fn.strdisplaywidth(char)
      if used + cells > limit then
        break
      end
      result = tail and char .. result or result .. char
      used = used + cells
    end
    return result
  end
  if mode == "end" then
    return take(budget, false) .. ellipsis
  end
  local prefix = math.floor(budget / 2)
  return take(prefix, false) .. ellipsis .. take(budget - prefix, true)
end

return M
