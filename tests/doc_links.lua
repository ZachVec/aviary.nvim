#!/usr/bin/env -S nvim -l

-- Check ./ and ../ Markdown links against the working tree and Marksman definitions.
-- Run with make links; MARKSMAN selects the server binary.

local root = vim.fn.fnamemodify(assert(debug.getinfo(1, "S").source):sub(2), ":p:h:h")

local marksman = vim.env.MARKSMAN
if not marksman or marksman == "" then
  marksman = vim.fn.executable("marksman") == 1 and "marksman" or nil
end
if not marksman then
  io.stderr:write("marksman not found; set MARKSMAN or install marksman\n")
  os.exit(2)
end

local problems = {}

---@param file string
---@param lnum integer
---@param message string
local function fail(file, lnum, message)
  problems[#problems + 1] = ("%s:%d: %s"):format(file, lnum, message)
end

---@param target string
---@return string
local function path_of(target)
  return target:match("^([^#]*)") or target
end

--- Whether the line prefix leaves an inline code span open.
---@param prefix string
---@return boolean
local function in_code_span(prefix)
  return select(2, prefix:gsub("`", "")) % 2 == 1
end

local files = vim.fn.systemlist({
  "git",
  "-C",
  root,
  "ls-files",
  "--cached",
  "--others",
  "--exclude-standard",
  "*.md",
})
if vim.v.shell_error ~= 0 then
  io.stderr:write("git ls-files failed\n")
  os.exit(2)
end
-- The index still names unstaged deletions; check the working tree's docs.
files = vim.tbl_filter(function(file)
  return vim.fn.filereadable(root .. "/" .. file) == 1
end, files)

--- Expected target for a Marksman definition query.
---@class DocLinkCase
---@field file string
---@field line integer 0-based
---@field character integer 0-based
---@field expected string absolute target path
---@field text string

---@type DocLinkCase[]
local cases = {}
local link_count = 0

for _, file in ipairs(files) do
  local dir = vim.fs.dirname(file)
  local lines = vim.fn.readfile(root .. "/" .. file)
  local fenced = false
  for lnum, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced then
      local label, definition = line:match("^%[([^%]]+)%]:%s*(%S+)%s*$")
      if label and not definition:match("^https?://") then
        fail(file, lnum, ("[%s] is a doc link written as a definition; spell it inline"):format(label))
      end
      local init = 1
      while true do
        local start, stop, text, target = line:find("%[([^%[%]]+)%]%(([^%)%s]+)%)", init)
        if not start then
          break
        end
        init = stop + 1
        if not in_code_span(line:sub(1, start - 1)) then
          link_count = link_count + 1
          local path = path_of(target)
          if path ~= "" and not target:match("^https?://") then
            if not path:match("^%.%.?/") then
              fail(file, lnum, ("relative target %s needs a ./ or ../ prefix"):format(target))
            else
              local abs = vim.fs.normalize(("%s/%s/%s"):format(root, dir, path))
              if vim.uv.fs_stat(abs) == nil then
                fail(file, lnum, ("target %s does not exist"):format(target))
              elseif path:match("%.md$") then
                cases[#cases + 1] = {
                  file = file,
                  line = lnum - 1,
                  character = start,
                  expected = abs,
                  text = text,
                }
              end
            end
          end
        end
      end
    end
  end
end

local buf = ""
local stderr = ""

local proc = vim.system({ marksman, "server" }, {
  stdin = true,
  stdout = function(_, data)
    if data then
      buf = buf .. data
    end
  end,
  stderr = function(_, data)
    if data then
      stderr = stderr .. data
    end
  end,
})

---@param message table
local function send(message)
  local body = vim.json.encode(message)
  proc:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
end

--- Read one framed JSON-RPC message, or nil on timeout.
---@param timeout integer
---@return table?
local function receive(timeout)
  local deadline = vim.uv.now() + timeout
  while true do
    local header_end = buf:find("\r\n\r\n", 1, true)
    if header_end then
      local length = tonumber(buf:sub(1, header_end - 1):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if length and #buf >= header_end + 3 + length then
        local body = buf:sub(header_end + 4, header_end + 4 + length - 1)
        buf = buf:sub(header_end + 4 + length)
        return vim.json.decode(body)
      end
    end
    if vim.uv.now() >= deadline then
      return nil
    end
    vim.wait(25, function()
      return false
    end)
  end
end

local next_id = 0

---@param method string
---@param params table
---@return integer
local function request(method, params)
  next_id = next_id + 1
  send({ jsonrpc = "2.0", id = next_id, method = method, params = params })
  return next_id
end

---@param method string
---@param params table
local function notify(method, params)
  send({ jsonrpc = "2.0", method = method, params = params })
end

---@type table<string, table[]>
local diagnostics = {}

---@param message table
local function handle(message)
  if message.method == "textDocument/publishDiagnostics" then
    diagnostics[message.params.uri] = message.params.diagnostics
  end
end

local root_uri = vim.uri_from_fname(root)
local initialize_id = request("initialize", {
  processId = vim.NIL,
  rootUri = root_uri,
  capabilities = vim.empty_dict(),
  workspaceFolders = { { uri = root_uri, name = "aviary" } },
})

local initialized = false
do
  local deadline = vim.uv.now() + 20000
  while vim.uv.now() < deadline do
    local message = receive(200)
    if message then
      if message.id == initialize_id then
        initialized = message.result ~= nil
        break
      end
      handle(message)
    end
  end
end
if not initialized then
  io.stderr:write(("marksman did not answer initialize%s\n"):format(stderr ~= "" and (": " .. stderr) or ""))
  pcall(proc.kill, proc, 15)
  os.exit(2)
end

notify("initialized", vim.empty_dict())

for _, file in ipairs(files) do
  notify("textDocument/didOpen", {
    textDocument = {
      uri = vim.uri_from_fname(root .. "/" .. file),
      languageId = "markdown",
      version = 1,
      text = table.concat(vim.fn.readfile(root .. "/" .. file), "\n"),
    },
  })
end

-- Clean documents publish nothing, so settle on silence rather than on a
-- number of notifications.
do
  local started = vim.uv.now()
  local last = started
  while vim.uv.now() - started < 20000 do
    local message = receive(200)
    if message then
      last = vim.uv.now()
      handle(message)
    elseif vim.uv.now() - last > 2000 and vim.uv.now() - started > 2500 then
      break
    end
  end
end

---@param uri string
---@return string
local function uri_to_relative(uri)
  local path = vim.uri_to_fname(uri)
  if path:sub(1, #root) == root then
    return path:sub(#root + 2)
  end
  return path
end

for _, case in ipairs(cases) do
  local id = request("textDocument/definition", {
    textDocument = { uri = vim.uri_from_fname(root .. "/" .. case.file) },
    position = { line = case.line, character = case.character },
  })
  local result
  local deadline = vim.uv.now() + 20000
  while vim.uv.now() < deadline do
    local message = receive(200)
    if message then
      if message.id == id then
        result = message.result
        break
      end
      handle(message)
    end
  end
  local target_uri = type(result) == "table" and (result.uri or result.targetUri) or nil
  if result == nil then
    fail(case.file, case.line + 1, ("marksman: no definition for [%s]"):format(case.text))
  elseif target_uri == nil then
    fail(case.file, case.line + 1, ("marksman: [%s] is ambiguous (%d destinations)"):format(case.text, #result))
  elseif vim.uri_to_fname(target_uri) ~= case.expected then
    fail(
      case.file,
      case.line + 1,
      ("marksman: [%s] jumps to %s, expected %s"):format(
        case.text,
        uri_to_relative(target_uri),
        uri_to_relative(vim.uri_from_fname(case.expected))
      )
    )
  end
end

for uri, items in pairs(diagnostics) do
  for _, item in ipairs(items) do
    fail(uri_to_relative(uri), item.range.start.line + 1, ("marksman: %s"):format(item.message))
  end
end

pcall(proc.kill, proc, 15)

if #problems > 0 then
  io.stderr:write(table.concat(problems, "\n") .. "\n")
  io.stderr:write(
    ("markdown links: %d problem(s) in %d files (%d links checked)\n"):format(#problems, #files, link_count)
  )
  os.exit(1)
end

print(("markdown links: %d checked across %d files, all resolve"):format(link_count, #files))
