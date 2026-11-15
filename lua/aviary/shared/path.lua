--- Path spelling, global cwd and Git worktree discovery.
--- cwd ignores :lcd/:tcd; git resolves from that global cwd on every call,
--- accepts .git files or directories, and returns nil plus a reason outside Git.
--- relpath keeps paths outside/equal to the base, or without a base, unchanged.
--- tilde folds only the HOME prefix for display.
---
--- truncate takes a normalized, slash-separated, single-line display path without
--- control characters and a nonnegative display-cell budget. It reads no context
--- or filesystem state. Fitting paths stay unchanged. Overflow keeps the first
--- directory and filename when possible, restoring whole trailing directories
--- before whole leading directories around one omitted middle segment.
--- Directories are never cut into partial names. A trailing slash marks a directory;
--- otherwise the last segment is a filename. Only oversized filenames shorten in
--- the middle, preserving composing characters and giving the suffix the odd cell.
--- The ellipsis is the minimum overflow result even when the budget cannot fit it.
--- Root prefixes also obey the budget; callers explicitly compose relpath and tilde
--- when wanted.
---@class aviary.shared.path
---@field cwd fun(): string normalized absolute global cwd
---@field git fun(): string?, string? normalized real worktree path, or nil and a reason
---@field tilde fun(path: string): string
---@field relpath fun(cwd: string|nil, path: string): string
---@field truncate fun(path: string, width: integer): string
local M = {}

function M.cwd()
  local cwd = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ":p"))
  if cwd == "/" or cwd:match("^%a:/$") then
    return cwd
  end
  return (cwd:gsub("/$", ""))
end

function M.git()
  local cwd = M.cwd()
  local root = vim.fs.root(cwd, ".git")
  if not root then
    return nil, "not a Git worktree: " .. cwd
  end
  return vim.fs.normalize(vim.uv.fs_realpath(root) or root), nil
end

function M.tilde(path)
  local home = vim.fn.getenv("HOME")
  if home == nil or home == vim.NIL or home == "" then
    return path
  end
  if path == home then
    return "~"
  end
  if vim.startswith(path, home .. "/") then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

function M.relpath(cwd, path)
  local ok, rel = pcall(vim.fs.relpath, cwd, path)
  if ok and rel and rel ~= "" and rel ~= "." then
    return rel
  end
  return path
end

function M.truncate(path, width)
  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end
  local prefix = path:match("^%a:/") or path:match("^/+") or ""
  local parts = {}
  for part in path:sub(#prefix + 1):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return "…"
  end
  local trailing = path:sub(-1) == "/" and "/" or ""
  local tail = parts[#parts] .. trailing
  local used = vim.fn.strdisplaywidth(tail)
  if used > width then
    if trailing ~= "" then
      return vim.fn.strdisplaywidth("…/") <= width and "…/" or "…"
    end
    return require("aviary.shared.text").truncate(tail, "middle", width)
  end

  local left, right = 0, #parts
  local marker = vim.fn.strdisplaywidth("…/")
  local head = vim.fn.strdisplaywidth(prefix .. parts[1]) + 1
  if #parts > 2 and head + marker + used <= width then
    left = 1
    used = used + head
  end
  used = used + marker
  if used > width then
    return tail
  end
  while right - left > 2 do
    local cells = vim.fn.strdisplaywidth(parts[right - 1]) + 1
    if used + cells > width then
      break
    end
    right = right - 1
    used = used + cells
  end
  if left > 0 then
    while right - left > 2 do
      local cells = vim.fn.strdisplaywidth(parts[left + 1]) + 1
      if used + cells > width then
        break
      end
      left = left + 1
      used = used + cells
    end
  end
  local start = left > 0 and prefix .. table.concat(parts, "/", 1, left) .. "/" or ""
  return start .. "…/" .. table.concat(parts, "/", right) .. trailing
end

return M
