--- Git queries for Review. All functions borrow the caller's flow context and
--- fixed repository root. Results are owned data, never command output records.
--- Queries may suspend in the owning flow and return complete data or raise.
--- Flow cancellation abandons pending queries.
local Async = require("aviary.shared.async")

---@class aviary.hawk.git.Entry
---@field root string absolute worktree path
---@field path string nonempty original repository-relative path, never a quoted patch header
---@field old_path? string rename/copy origin; nil otherwise
---@field status "A"|"M"|"D"|"R"|"C"|"T"
---@field kind "text"|"binary"|"submodule"
---@field added? integer nil when text counts are unavailable
---@field removed? integer nil when text counts are unavailable
---@field old_blob? string fixed object ID; nil when absent/unreadable
---@field new_blob? string fixed object ID; nil when absent/unreadable

---@class aviary.hawk.git.Versions
---@field old string complete left bytes. Empty when the old side is absent.
---@field new string complete right bytes. Empty when the new side is absent.

---@class aviary.hawk.git.Error
---@field message string Git stderr, or an exit status when stderr is empty

---@class aviary.hawk.git
---@field Error table metatable of a failed comparison command
---@field merge_base fun(ctx: AsyncContext, root: string, old: string, new: string): string common ancestor's full SHA for the given revisions
---@field diff fun(ctx: AsyncContext, root: string, old: string, new: string): aviary.hawk.git.Entry[] sorted metadata captured from the two revisions
---@field versions fun(ctx: AsyncContext, root: string, old_oid?: string, new_oid?: string): aviary.hawk.git.Versions Read captured blobs concurrently.
local M = {
  Error = {
    ---@param self aviary.hawk.git.Error
    __tostring = function(self)
      return self.message
    end,
  },
}

---@param ... string literal Git arguments, never shell text
---@return Cmd command description; construction does not start a process
local function git(...)
  return Async({ "git", "--no-pager", "--literal-pathspecs", "-c", "core.quotepath=false", ... })
end

---@param oid string
---@return string?
local function blob(oid)
  return not oid:match("^0+$") and oid or nil
end

--- --raw and --numstat share one Git invocation and use NUL-delimited paths.
--- Blob IDs preserve the compared contents when refs move later.
---@param root string
---@param output string
---@return aviary.hawk.git.Entry[]
local function parse(root, output)
  local tokens = output:gmatch("([^%z]*)%z")
  local result, by_path = {}, {}
  while true do
    local token = tokens()
    if not token then
      break
    end
    if token:sub(1, 1) == ":" then
      local old_mode, new_mode, old_oid, new_oid, status = token:match("^:(%d+) (%d+) (%x+) (%x+) (%u)")
      if not status then
        error("invalid Git raw record", 0)
      end
      local path, old_path = assert(tokens()), nil
      if status == "R" or status == "C" then
        old_path, path = path, assert(tokens())
      end
      local kind = (old_mode == "160000" or new_mode == "160000") and "submodule" or "text"
      local item = {
        root = root,
        path = path,
        old_path = old_path,
        status = status,
        kind = kind,
        old_blob = blob(old_oid),
        new_blob = blob(new_oid),
      }
      result[#result + 1], by_path[path] = item, item
    elseif token ~= "" then
      local added, removed, path = token:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
      if not path then
        error("invalid Git numstat record", 0)
      end
      if path == "" then
        tokens()
        path = assert(tokens())
      end
      local item = assert(by_path[path], "missing Git raw record")
      if item.kind == "text" then
        if added == "-" then
          item.kind = "binary"
        else
          item.added, item.removed = tonumber(added), tonumber(removed)
        end
      end
    end
  end
  table.sort(result, function(a, b)
    return a.path < b.path
  end)
  return result
end

--- Preserve Git's diagnostic separately from Lua parsing and rendering errors.
---@param ctx AsyncContext
---@param root string
---@param command Cmd
---@return string
local function stdout(ctx, root, command)
  local result = command:run(ctx, { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" } }):wait()
  if result.code ~= 0 then
    local message = result.stderr:gsub("\n$", "")
    error(setmetatable({ message = message ~= "" and message or ("command exited with " .. result.code) }, M.Error), 0)
  end
  return result.stdout
end

function M.merge_base(ctx, root, old, new)
  return vim.trim(stdout(ctx, root, git("merge-base", "--end-of-options", old, new)))
end

function M.diff(ctx, root, old, new)
  local command = git(
    "diff",
    "--no-ext-diff",
    "--no-textconv",
    "--no-color",
    "--no-relative",
    "--find-renames",
    "--raw",
    "--numstat",
    "--no-abbrev",
    "-z",
    "--end-of-options",
    old,
    new,
    "--"
  )
  return parse(root, stdout(ctx, root, command))
end

function M.versions(ctx, root, old_oid, new_oid)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  -- Start both reads before either wait so their work can overlap.
  local old = old_oid and git("cat-file", "blob", old_oid):run(ctx, opts)
  local new = new_oid and git("cat-file", "blob", new_oid):run(ctx, opts)
  return {
    old = old and old:wait().stdout or "",
    new = new and new:wait().stdout or "",
  }
end

return M
