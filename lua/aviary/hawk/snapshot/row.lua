--- Review rows describe list content. Custom actions borrow read-only row fields
--- and call edit to update a draft or jump to preview a change.
local Async = require("aviary.shared.async")
local Git = require("aviary.hawk.git")

---@alias aviary.hawk.snapshot.row.Input
---| { kind: "revision", root: string }
---| { kind: "choice", choices: string[] }

---@class aviary.hawk.snapshot.row.RenderedRow
---@field text string single-line buffer text
---@field marks { namespace: integer, column: integer, opts: vim.api.keyset.set_extmark }[] zero-based byte columns

---@class aviary.hawk.snapshot.row.Row
---@field kind "meta"|"diff"
---@field render fun(self: self, label_ns: integer, value_ns: integer): aviary.hawk.snapshot.row.RenderedRow Describe the row for the Tab using its extmark namespaces.

---@class aviary.hawk.snapshot.row.MetaRow: aviary.hawk.snapshot.row.Row
---@field kind "meta"
---@field label string
---@field private highlights string[]
---@field private placeholder string
---@field value string current draft
---@field input aviary.hawk.snapshot.row.Input
---@field edit fun(self: self, value: string) Set a single-line draft. Empty or whitespace-only input clears it. The caller redraws the changed row through its Tab.
local MetaRow = {}
MetaRow.__index = MetaRow

---@class aviary.hawk.snapshot.row.RevisionRow: aviary.hawk.snapshot.row.MetaRow
local RevisionRow = setmetatable({}, { __index = MetaRow })
RevisionRow.__index = RevisionRow

---@class aviary.hawk.snapshot.row.DiffRow: aviary.hawk.snapshot.row.Row
---@field kind "diff"
---@field root string absolute worktree path
---@field path string repository-relative path
---@field old_path? string rename or copy source
---@field status "A"|"M"|"D"|"R"|"C"|"T"
---@field file_kind "text"|"binary"|"submodule"
---@field added? integer
---@field removed? integer
---@field private old_blob? string captured object ID
---@field private new_blob? string captured object ID
---@field jump fun(self: self, tab: aviary.hawk.Tab) Preview this row in its open Tab while preserving focus.
local DiffRow = {}
DiffRow.__index = DiffRow

---@class aviary.hawk.snapshot.row
---@field revision fun(label: string, root: string): aviary.hawk.snapshot.row.RevisionRow Create an empty revision draft for the given repository.
---@field diff fun(entry: aviary.hawk.git.Entry): aviary.hawk.snapshot.row.DiffRow Take ownership of one Git entry and convert it into a change row in place.
local M = {}

local LABEL_HIGHLIGHTS = { "@markup.italic", "Title" }
local REVISION_PLACEHOLDER = "Git revision (e.g. HEAD~1)"
local STATUS_HL = {
  A = "Added",
  C = "Added",
  D = "Removed",
  M = "Changed",
  R = "Changed",
  T = "Changed",
}

function M.revision(label, root)
  return setmetatable({
    kind = "meta",
    label = label,
    highlights = LABEL_HIGHLIGHTS,
    placeholder = REVISION_PLACEHOLDER,
    value = "",
    input = { kind = "revision", root = root },
  }, RevisionRow)
end

function M.diff(entry)
  local row = setmetatable(entry, DiffRow) --[[@as aviary.hawk.snapshot.row.DiffRow]]
  row.file_kind, row.kind = entry.kind, "diff"
  return row
end

function MetaRow:render(label_ns, _)
  local marks = {
    {
      namespace = label_ns,
      column = 0,
      opts = {
        virt_text = { { self.label, self.highlights } },
        virt_text_pos = "inline",
        line_hl_group = "Visual",
      },
    },
  }
  if self.value == "" then
    marks[2] = {
      namespace = label_ns,
      column = 0,
      opts = {
        virt_text = { { self.placeholder, "Comment" } },
        virt_text_win_col = vim.fn.strdisplaywidth(self.label),
        hl_mode = "combine",
      },
    }
  end
  -- A real cell keeps the cursor after an inline label on an empty row.
  return { text = self.value == "" and " " or self.value, marks = marks }
end

function MetaRow:edit(value)
  if type(value) ~= "string" or value:find("^[ \r\n\t]*$") then
    value = ""
  end
  self.value = value
end

function DiffRow:render(_, value_ns)
  local added = self.added and ("+" .. (self.added >= 10000 and "10k+" or self.added)) or "—"
  local removed = self.removed and ("-" .. (self.removed >= 10000 and "10k+" or self.removed)) or "—"
  local path = (self.old_path and (self.old_path .. " → " .. self.path) or self.path):gsub("%c", " ")
  local text = "  " .. self.status .. " " .. path .. " " .. added .. " " .. removed
  local path_end = 4 + #path
  local added_end = path_end + 1 + #added
  return {
    text = text,
    marks = {
      { namespace = value_ns, column = 2, opts = { end_col = 3, hl_group = STATUS_HL[self.status] } },
      { namespace = value_ns, column = 4, opts = { end_col = path_end, hl_group = "Directory" } },
      { namespace = value_ns, column = path_end + 1, opts = { end_col = added_end, hl_group = "Added" } },
      { namespace = value_ns, column = added_end + 1, opts = { end_col = #text, hl_group = "Removed" } },
    },
  }
end

---@param buf integer
---@param name string
---@param text string
---@param ft string
local function fill(buf, name, text, ft)
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    table.remove(lines)
  end
  vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_call(buf, function()
    -- Avoid FileType hooks attaching editing tools to readonly version buffers.
    vim.cmd({ cmd = "setlocal", args = { "filetype=" .. ft }, mods = { noautocmd = true } })
  end)
  vim.bo[buf].endofline = text:sub(-1) == "\n"
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
  vim.bo[buf].syntax = ft
end

function DiffRow:jump(tab)
  if tab.cancel_body then
    tab.cancel_body()
  end
  tab.cancel_body = Async.run(function(ctx)
    local old_path, new_path = self.old_path or self.path, self.path
    local text
    local old_ft, new_ft = "", ""
    if self.file_kind == "text" then
      text = Git.versions(ctx, self.root, self.old_blob, self.new_blob)
      old_ft = vim.filetype.match({ filename = old_path }) or ""
      new_ft = vim.filetype.match({ filename = new_path }) or ""
    else
      local old, new = self.old_blob or "absent", self.new_blob or "absent"
      text = { old = ("[%s] %s\n"):format(self.file_kind, old), new = ("[%s] %s\n"):format(self.file_kind, new) }
    end
    fill(tab.old_buf, ("%d:old/%s"):format(tab.tabpage, (old_path:gsub("%c", " "))), text.old, old_ft)
    fill(tab.new_buf, ("%d:new/%s"):format(tab.tabpage, (new_path:gsub("%c", " "))), text.new, new_ft)
    for _, win in ipairs({ tab.old_win, tab.new_win }) do
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
    vim.api.nvim_win_call(tab.new_win, function()
      vim.cmd("diffupdate")
    end)
  end)
end

return M
