--- Review comparisons, Change behavior and repository observation. Queries borrow the caller's
--- AsyncContext, return data or raise, and retain no query results. Comparison
--- choices are captured by the caller before yielding and remain read-only.
--- Missing repositories produce an empty list without running Git.
--- start returns an idempotent stop function; observation follows global cwd and
--- pauses outside Git. User AviaryReviewChanged signals
--- discovery completion and directory changes; filesystem bursts are debounced.
--- Notifications are refresh hints; nested-ref-only changes may be missed.
--- Background discovery and observation acquisition failures are reported after
--- cleanup. Filesystem errors stop observation for the current repository and
--- raise on the main loop. Directory changes can restart observation after
--- either background failure.
local Async = require("aviary.shared.async")
local Debounce = require("aviary.shared.debounce")
local Git = require("aviary.hawk.review.git")
local Path = require("aviary.shared.path")
local Text = require("aviary.shared.text")
local transaction = require("aviary.shared.transaction")

---@class aviary.hawk.review.Context
---@field root? string captured repository root; nil returns an empty comparison
---@field base? string full ref name, fixed commit SHA or HEAD; nil uses HEAD on each read
---@field target string full ref name, fixed commit SHA, HEAD or "index"
---@field style "direct"|"merge_base" comparison mode

---@class aviary.hawk.Change: aviary.hawk.review.git.Entry, aviary.hawk.Item
---@field base string captured effective base revision used to name the left version
---@field target string captured target revision or index used to name the right version
---@field render fun(self: aviary.hawk.Change, width: integer): aviary.hawk.RenderedItem render status, path and unpadded counts separated by single spaces; width is non-negative text-area cells; paths omit whole directories, rename pairs shorten as text
local Change = {}
Change.__index = Change

---@class aviary.hawk.review.Choice
---@field label string picker display text
---@field revision string full ref name, fixed commit SHA or "index"

---@class aviary.hawk.review.Review
---@field read fun(ctx: AsyncContext, selection: aviary.hawk.review.Context): aviary.hawk.Change[], string? compare commits/index; missing root returns an empty list and nil base without running Git
---@field text fun(ctx: AsyncContext, item: aviary.hawk.Change): aviary.hawk.review.git.Versions read captured blobs; non-text items return descriptions
---@field choices fun(ctx: AsyncContext, root: string, kind: "ref"|"commit", include_index: boolean): aviary.hawk.review.Choice[] list finite candidates without fetching or checking out
---@field start fun(): fun() follow global cwd, observing Git when available; returned stop releases observation idempotently
local M = {}

--- Complete native observation, published only after acquisition succeeds.
--- Queued callbacks do nothing before publication or after its handles are released.
---@class aviary.hawk.review.GitWatch
---@field package _debounce aviary.shared.Debounce owned refresh debounce
---@field package _watches uv.uv_fs_event_t[] owned directory watches; empty after close
local Watch = {}
Watch.__index = Watch

local status_hl = {
  A = "Added",
  C = "Added",
  D = "Removed",
  M = "Changed",
  R = "Changed",
  T = "Changed",
  U = "DiagnosticWarn",
}

function Change:render(width)
  local added = self.added and ("+" .. (self.added >= 10000 and "10k+" or self.added)) or "—"
  local removed = self.removed and ("-" .. (self.removed >= 10000 and "10k+" or self.removed)) or "—"
  local changes = added .. " " .. removed
  local path = (self.old_path and (self.old_path .. " → " .. self.path) or self.path):gsub("%c", " ")
  local budget = math.max(0, width - 3 - vim.fn.strdisplaywidth(changes))
  path = self.old_path and Text.truncate(path, "middle", budget) or Path.truncate(path, budget)
  local text = self.status .. " " .. path .. " " .. changes
  local path_end = 2 + #path
  local added_end = path_end + 1 + #added
  return {
    text = text,
    highlights = {
      { start_col = 0, end_col = 1, hl = status_hl[self.status] },
      { start_col = 2, end_col = path_end, hl = "Directory" },
      { start_col = path_end + 1, end_col = added_end, hl = "Added" },
      { start_col = added_end + 1, end_col = #text, hl = "Removed" },
    },
  }
end

function M.read(ctx, selection)
  local root = selection.root
  if not root then
    return {}, nil
  end
  local revision = selection.base or "HEAD"
  local base, target = revision, selection.target
  if selection.style == "merge_base" then
    base = Git.merge_base(ctx, root, base, target == "index" and "HEAD" or target)
  end
  local items = Git.diff(ctx, root, base, target)
  -- Git transfers these records; install Change behavior without copying fields.
  for _, item in ipairs(items) do
    local change = setmetatable(item, Change)
    change.base, change.target = base, target
  end
  return items, revision
end

function M.text(ctx, item)
  if item.kind ~= "text" then
    return {
      old = ("[%s] %s\n"):format(item.kind, item.old_blob or "absent"),
      new = ("[%s] %s\n"):format(item.kind, item.new_blob or "absent"),
    }
  end
  return Git.versions(ctx, item.root, item.old_blob, item.new_blob)
end

function M.choices(ctx, root, kind, include_index)
  local choices = {}
  if include_index then
    choices[#choices + 1] = { label = "index", revision = "index" }
  end
  if kind == "ref" then
    for _, ref in ipairs(Git.refs(ctx, root)) do
      choices[#choices + 1] = { label = ref, revision = ref }
    end
  else
    for _, commit in ipairs(Git.commits(ctx, root)) do
      choices[#choices + 1] = { label = commit.summary, revision = commit.oid }
    end
  end
  return choices
end

--- Acquire debounce and native handles synchronously, returning a complete Watch
--- after success. Acquisition failures roll back before raising to the caller.
---@param directories string[] unique absolute Git metadata directories
---@return aviary.hawk.review.GitWatch watch owns acquired native resources
function Watch.new(directories)
  local watch

  ---@param err? string
  ---@param filename? string nil when the backend cannot identify a particular entry
  local function on_event(err, filename)
    local current = watch
    if not current or #current._watches == 0 then
      return
    end
    if err then
      -- fs_event callbacks are fast events; raise on the main loop after cleanup.
      vim.schedule(function()
        if #current._watches > 0 then
          current:close()
          error(err, 0)
        end
      end)
      return
    end
    if filename and filename:match("%.lock$") then
      return
    end
    current._debounce:reset(100)
  end

  watch = transaction(function(txn)
    local debounce = txn:acquire(function()
      return Debounce.new(function()
        vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
      end)
    end, Debounce.close)
    local watches = {}
    for _, dir in ipairs(directories) do
      local handle = txn:acquire(function()
        return assert(vim.uv.new_fs_event())
      end, function(acquired)
        acquired:close()
      end)
      assert(handle:start(dir, {}, on_event))
      watches[#watches + 1] = handle
    end
    return setmetatable({ _debounce = debounce, _watches = watches }, Watch)
  end)
  return watch
end

--- Idempotently release native resources and suppress late callbacks.
---@return nil
function Watch:close()
  self._debounce:close()
  for _, handle in ipairs(self._watches) do
    handle:close()
  end
  self._watches = {}
end

function M.start()
  return transaction(function(txn)
    local current, observer, cancel
    local function rewatch(root)
      if cancel then
        cancel()
      end
      if current then
        current:close()
        current = nil
      end
      cancel = root
        and Async.run(function(ctx)
          local directories = Git.metadirs(ctx, root)
          current = Watch.new(directories)
          vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false }) -- cover metadata changes during discovery
        end)
    end
    txn:on_rollback(rewatch)
    observer = txn:acquire(function()
      return vim.api.nvim_create_autocmd("DirChanged", {
        pattern = "global",
        callback = function()
          rewatch(Path.git())
          vim.api.nvim_exec_autocmds("User", { pattern = "AviaryReviewChanged", modeline = false })
        end,
      })
    end, vim.api.nvim_del_autocmd)
    rewatch(Path.git())
    return function()
      if observer then
        vim.api.nvim_del_autocmd(observer)
        observer = nil
        rewatch()
      end
    end
  end)
end

return M
