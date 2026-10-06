--- aviary: one plugin, several birds.
---
--- The composition root. It holds the shared config table and gives lazy
--- access to the subsystems — `require("aviary").hawk`,
--- `require("aviary").pigeon` — so naming a subsystem is what loads it.
---
--- Nothing here installs a user command or touches `_G`: a subsystem is
--- called from Lua. See docs/migration.md for what is wired when.
local M = {}

--- Every subsystem's slice of the configuration, as `setup` merged it. Each
--- subsystem resolves its own slice with its own rules when it applies its
--- options; this module never reads one for it.
---@type table<string, table>
M.config = {}

setmetatable(M, {
  __index = function(t, k)
    ---@diagnostic disable-next-line: no-unknown
    t[k] = require("aviary." .. k)
    return rawget(t, k)
  end,
})

--- Merge `opts` into the shared config and return this module.
---
--- Merging alone never loads a subsystem: a caller reads the slice it needs
--- (`require("aviary").config.hawk`) when it resolves its options. Until a
--- subsystem's own `setup` is wired to these slices (see docs/migration.md),
--- configure one the way it has always been configured —
--- `require("aviary").hawk.setup({ ... })`.
---@param opts? table
---@return table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  return M
end

return M
