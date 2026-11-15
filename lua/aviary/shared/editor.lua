--- Editor selection and window text-area geometry shared by features.
--- text_width measures nonnegative cells after native gutters. An optional
--- nonnegative line_count anticipates absolute-number width without changing the
--- buffer; zero represents one empty line. Other gutters retain measured width.
--- selection captures whole lines from active character/line/block Visual mode,
--- or the cursor line, including unnamed buffers. It exits Visual mode to update
--- marks and returns ordered 1-based inclusive rows.
---
--- ```lua
--- local Editor = require("aviary.shared.editor")
--- local first, last = Editor.selection()
--- local width = Editor.text_width(vim.api.nvim_get_current_win())
--- ```
---@class aviary.shared.editor
---@field text_width fun(win: integer, line_count?: integer): integer valid window; nil measures current rows
---@field selection fun(): integer, integer
local M = {}

function M.text_width(win, line_count)
  local info = vim.fn.getwininfo(win)[1]
  local width = info.width - info.textoff
  local options = vim.wo[win]
  if line_count and options.number and options.statuscolumn == "" then
    ---@type fun(count: integer): integer
    local function number_width(count)
      return math.max(options.numberwidth, #tostring(math.max(1, count)) + 1)
    end
    local current = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    width = width + number_width(current) - number_width(line_count)
  end
  return math.max(0, width)
end

function M.selection()
  if vim.api.nvim_get_mode().mode:match("[vV\22]") then
    vim.cmd("normal! \27")
    local start_row, end_row = vim.fn.line("'<"), vim.fn.line("'>")
    if start_row > end_row then
      start_row, end_row = end_row, start_row
    end
    return start_row, end_row
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return row, row
end

return M
