--- Git queries for Review. All functions borrow the caller's flow context and
--- fixed repository root. Results are owned data, never command output records.
--- Queries may suspend in the owning flow and return complete data or raise.
--- Flow cancellation abandons pending queries.
local Async = require("aviary.shared.async")

---@class aviary.hawk.review.git.Entry
---@field root string absolute worktree path
---@field path string original repository-relative path, never a quoted patch header
---@field old_path? string rename/copy origin; nil otherwise
---@field status "A"|"M"|"D"|"R"|"C"|"T"|"U"
---@field kind "text"|"binary"|"submodule"|"unmerged"
---@field added? integer nil when text counts are unavailable
---@field removed? integer nil when text counts are unavailable
---@field old_blob? string fixed object ID; nil when absent/unreadable
---@field new_blob? string fixed object ID; nil when absent/unreadable

---@class aviary.hawk.review.git.Commit
---@field oid string full commit SHA
---@field summary string abbreviated SHA and commit subject

---@class aviary.hawk.review.git.Versions
---@field old string complete left bytes; empty when no old object exists
---@field new string complete right bytes; empty when no new object exists

---@class aviary.hawk.review.git
---@field merge_base fun(ctx: AsyncContext, root: string, base: string, target: string): string common ancestor's full SHA
---@field diff fun(ctx: AsyncContext, root: string, base: string, target: string): aviary.hawk.review.git.Entry[] sorted captured metadata; target may be index
---@field versions fun(ctx: AsyncContext, root: string, old_oid?: string, new_oid?: string): aviary.hawk.review.git.Versions read independent objects concurrently
---@field refs fun(ctx: AsyncContext, root: string): string[] sorted non-symbolic local, remote and tag ref names
---@field commits fun(ctx: AsyncContext, root: string): aviary.hawk.review.git.Commit[] finite commits reachable from refs or HEAD
---@field metadirs fun(ctx: AsyncContext, root: string): string[] unique normalized absolute gitdir/commondir paths
local M = {}

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

--- --raw and --numstat share one Git invocation/index read. Both use NUL paths;
--- blob IDs freeze the represented versions even when refs/index move later.
---@param root string
---@param output string
---@return aviary.hawk.review.git.Entry[]
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
      local kind = status == "U" and "unmerged"
        or (old_mode == "160000" or new_mode == "160000") and "submodule"
        or "text"
      local item = {
        root = root,
        path = path,
        old_path = old_path,
        status = status,
        kind = kind,
        old_blob = kind ~= "unmerged" and blob(old_oid) or nil,
        new_blob = kind ~= "unmerged" and blob(new_oid) or nil,
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

function M.merge_base(ctx, root, base, target)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  return vim.trim(git("merge-base", base, target):run(ctx, opts):wait().stdout)
end

function M.diff(ctx, root, base, target)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  local revisions = target == "index" and { "--cached", base, "--" } or { base, target, "--" }
  local output = git(
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
      unpack(revisions)
    )
    :run(ctx, opts)
    :wait().stdout
  return parse(root, output)
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

function M.refs(ctx, root)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  local output =
    git("for-each-ref", "--sort=refname", "--format=%(refname)%00%(symref)", "refs/heads", "refs/remotes", "refs/tags")
      :run(ctx, opts)
      :wait().stdout
  local refs = {}
  for ref, symbolic in output:gmatch("([^%z\n]+)%z([^\n]*)\n") do
    if symbolic == "" then
      refs[#refs + 1] = ref
    end
  end
  return refs
end

function M.commits(ctx, root)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  local output = git("log", "--all", "HEAD", "--format=%H%x00%h %s%x00", "-z"):run(ctx, opts):wait().stdout
  local commits = {}
  for oid, summary in output:gmatch("(%x+)%z([^%z]+)%z") do
    commits[#commits + 1] = { oid = oid, summary = summary }
  end
  return commits
end

function M.metadirs(ctx, root)
  local opts = { cwd = root, env = { GIT_OPTIONAL_LOCKS = "0" }, check = { 0 } }
  local output =
    git("rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"):run(ctx, opts):wait().stdout
  local directories = {}
  for dir in output:gmatch("[^\n]+") do
    directories[vim.fs.normalize(dir)] = true
  end
  return vim.tbl_keys(directories)
end

return M
