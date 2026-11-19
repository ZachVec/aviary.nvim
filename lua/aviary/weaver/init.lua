--- Weaver captures editor input and composes Messages, without choosing a target.
--- These internal collectors serve the public delivery table in aviary/init.lua.
--- Collectors pass complete Messages to on_message; cancellation is quiet.
--- Callbacks may run immediately or later; startup and callback errors propagate.
--- Collectors return no Message; the callback owns subsequent use of the result.
--- Selection and prompt configuration are captured before the picker changes focus.
--- Prompt/Text capture exits active Visual mode and retains no source anchors.
--- The line placeholder captures inclusive Visual rows, or the current row in
--- Normal mode. Single-row references retain an omitted end row.
--- Configured resolvers run after confirmation, in token order, once per occurrence.
--- They borrow the captured Selection and return Messages; exceptions propagate.
--- Tokens without a resolver remain literal Text.
--- See docs/weaver.md and docs/weaver/glossary.md.
local Config = require("aviary.weaver.config")
local Editor = require("aviary.shared.editor")
local Message = require("aviary.shared.message")
local Notify = require("aviary.shared.notify")
local Picker = require("aviary.weaver.picker")

--- Captured whole-line range; keep unchanged when resolving a template.
---@class aviary.weaver.Selection
---@field path string captured absolute filename, or empty for an unnamed buffer
---@field start_row integer captured first selected row or cursor row
---@field end_row? integer captured last selected row; omitted for a single row

---@class aviary.weaver.Module
---@field setup fun(opts?: aviary.weaver.ConfigOverrides): boolean, string? rebuild from defaults and opts; invalid configuration preserves previous options
---@field prompt fun(on_message: fun(message: aviary.shared.Message)) capture filename and current line or active Visual whole-line range, then select a named template
---@field files fun(on_message: fun(message: aviary.shared.Message)) select files and compose references after picker cleanup
---@field buffers fun(on_message: fun(message: aviary.shared.Message)) select named file buffers and compose references after picker cleanup
---@field text fun(on_message: fun(message: aviary.shared.Message)) capture current line or active Visual whole lines verbatim, including empty text
local M = {}

---@type fun(source: aviary.weaver.picker.Source, on_message: fun(message: aviary.shared.Message))
local function pick(source, on_message)
  Picker.pick(source, function(paths)
    local references = {}
    for _, path in ipairs(paths) do
      references[#references + 1] = Message.reference(path)
    end
    on_message(Message.join(Config().references.join, references))
  end)
end

function M.setup(opts)
  return Config.setup(opts)
end

function M.prompt(on_message)
  local config = Config()
  local names = vim.tbl_keys(config.prompts)
  if #names == 0 then
    Notify.warn("weaver: no prompts are configured")
    return
  end
  table.sort(names)

  local path = vim.api.nvim_buf_get_name(0)
  local first, last = Editor.selection()
  local selection = { path = path, start_row = first, end_row = first ~= last and last or nil }
  vim.ui.select(names, { prompt = "Prompt: " }, function(name)
    if not name then
      return
    end
    local template = config.prompts[name]
    local children = {}
    local from = 1
    for at, token, after in template:gmatch("(){([%w_]+)}()") do
      local resolve = config.resolvers[token]
      if resolve then
        children[#children + 1] = Message.text(template:sub(from, at - 1))
        children[#children + 1] = resolve(selection)
        from = after
      end
    end
    children[#children + 1] = Message.text(template:sub(from))
    on_message(Message.join("", children))
  end)
end

function M.files(on_message)
  pick("files", on_message)
end

function M.buffers(on_message)
  pick("buffers", on_message)
end

function M.text(on_message)
  local first, last = Editor.selection()
  local text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
  on_message(Message.text(text))
end

return M
