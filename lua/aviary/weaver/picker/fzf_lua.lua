--- Use fzf-lua's built-in sources and parser for decorated selection lines.
local M = {}
M.requires = "fzf-lua"

---@class aviary.weaver.picker.FzfEntry
---@field path? string absolute path decoded by entry_to_file

---@param source aviary.weaver.picker.Source
---@param cwd string captured global cwd
---@param on_confirm fun(paths: string[])
---@param opts aviary.weaver.picker.AdapterOpts
function M.pick(source, cwd, on_confirm, opts)
  local picker_opts = {
    actions = {
      ["default"] = function(selected, options)
        local paths = {}
        for _, line in ipairs(selected) do
          ---@type aviary.weaver.picker.FzfEntry
          local entry = require("fzf-lua.path").entry_to_file(line, options)
          if entry.path then
            paths[#paths + 1] = entry.path
          end
        end
        -- fzf-lua closes before dispatch; defer callbacks past its error handler.
        vim.schedule(function()
          on_confirm(paths)
        end)
      end,
    },
  }
  if source == "files" then
    picker_opts.cwd, picker_opts.follow = cwd, true
  else
    -- fzf-lua treats a buffers cwd option as a restriction, so leave it unset.
    picker_opts.filter = opts.filter
  end
  require("fzf-lua")[source](picker_opts)
end

return M
