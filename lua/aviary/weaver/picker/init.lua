--- File and buffer selection through built-in picker sources.
--- Backends own discovery, preview, and process lifetimes. Callers receive paths.
--- Adapter contracts live below; configuration belongs to Weaver.
--- Design: docs/weaver/picker-decisions.md.
---
--- ```lua
--- require("aviary.weaver.picker").pick("files", function(paths)
---   print(table.concat(paths, "\n"))
--- end)
--- ```

---@alias aviary.weaver.picker.Source "files"|"buffers"

---@class aviary.weaver.picker.AdapterOpts
---@field filter? fun(buf: integer): boolean buffer predicate; nil keeps the backend's buffer filtering unchanged; ignored for files

--- Private backend interface; report selected absolute paths in selection order
--- after the picker UI closes. Each confirmation, including after resume, may
--- report again. Empty paths or no report mean cancellation.
---@class aviary.weaver.picker.Adapter
---@field requires string runtime module dependency
---@field pick fun(source: aviary.weaver.picker.Source, cwd: string, on_confirm: fun(paths: string[]), opts: aviary.weaver.picker.AdapterOpts)

local Config = require("aviary.weaver.config")

local M = {}

local adapters = {
  snacks = "aviary.weaver.picker.snacks",
  ["fzf-lua"] = "aviary.weaver.picker.fzf_lua",
}

---@param buf integer valid buffer handle supplied by the picker
---@return boolean eligible whether the buffer can supply a file reference
local function eligible_buffer(buf)
  return vim.bo[buf].buflisted
    and vim.bo[buf].buftype == ""
    and vim.fn.filereadable(vim.api.nvim_buf_get_name(buf)) == 1
end

--- Select absolute file paths through a built-in source, never buffer contents.
--- Files browse global cwd following symlinks; buffers select listed, named,
--- normal buffers backed by readable files, including those outside cwd.
--- Cancellation does not call on_confirm. Startup and callback errors propagate.
---@param source aviary.weaver.picker.Source built-in file or buffer source
---@param on_confirm fun(paths: string[]) called after UI cleanup for each nonempty confirmation with absolute paths in selection order
---@return nil
function M.pick(source, on_confirm)
  local name = Config().picker
  ---@type aviary.weaver.picker.Adapter
  local adapter = require(adapters[name])
  local ok, reason = pcall(require, adapter.requires)
  if not ok then
    error(("aviary: picker '%s' requires '%s' (%s)"):format(name, adapter.requires, tostring(reason)), 0)
  end
  -- Capture :cd before a picker can change focus or cwd.
  local cwd = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ":p"))
  local opts = { filter = source == "buffers" and eligible_buffer or nil }
  adapter.pick(source, cwd, function(paths)
    if #paths > 0 then
      on_confirm(paths)
    end
  end, opts)
end

return M
