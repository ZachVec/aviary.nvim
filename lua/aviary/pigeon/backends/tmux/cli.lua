--- Synchronous operations on the default tmux server (TMUX required).
--- Each Agent owns one persistent session with exactly one marked window/pane.
--- Clients attach directly to that session; no temporary session is created.
--- Native errors raise; multi-step acquisitions roll back before raising.
local Process = require("aviary.shared.process")
local transaction = require("aviary.shared.transaction")

---@class aviary.pigeon.tmux.Record
---@field session string persistent session name holding this Agent
---@field pane string agent pane id
---@field tool string local tool configuration key
---@field cwd string absolute Agent launch directory

---@class aviary.pigeon.tmux.cli
---@field list fun(): aviary.pigeon.tmux.Record[] marked Agent records
---@field current fun(client: string): aviary.pigeon.tmux.Record Agent displayed by client; raises when the client is not attached to a Pigeon Agent
---@field create fun(tool: string, argv: string[], cwd: string): aviary.pigeon.tmux.Record
---@field attach fun(session: string): string[] argv attaching one client directly to the Agent session
---@field retarget fun(client: string, session: string) move an existing client to the Agent session
---@field paste fun(pane: string, text: string) preserve raw LF, request bracketed paste, never submit
local M = {}
local buffer_name = "aviary-pigeon-" .. vim.fn.getpid()
local fields = { "pane_id", "@pigeon_session", "@pigeon_tool", "pane_start_path" }
local format = table.concat(vim.tbl_map(function(field)
  return "#{n:" .. field .. "}:#{" .. field .. "}"
end, fields))
local client_fields = { "client_name", "pane_id", "@pigeon_session", "@pigeon_tool", "pane_start_path" }
local client_format = table.concat(vim.tbl_map(function(field)
  return "#{n:" .. field .. "}:#{" .. field .. "}"
end, client_fields))

---@param args string[]
---@param stdin? string
---@return string
local function tmux(args, stdin)
  local result = Process.run(vim.list_extend({ "tmux" }, args), { stdin = stdin, text = false })
  assert(result.code == 0, result.stderr)
  return result.stdout
end

---@param value string
---@return string
local function argument(value)
  return (value:gsub(";$", "\\;"))
end

---@param output string length-prefixed native fields; names and paths may contain separators
---@param position integer
---@param count integer
---@return string[] values
---@return integer next_position
local function read_fields(output, position, count)
  local values = {}
  for index = 1, count do
    local colon = assert(output:find(":", position, true), "invalid tmux record")
    local length = assert(tonumber(output:sub(position, colon - 1)), "invalid tmux field length")
    local last = colon + length
    assert(length >= 0 and last <= #output, "truncated tmux field")
    values[index], position = output:sub(colon + 1, last), last + 1
  end
  return values, position
end

---@param output string length-prefixed native fields
---@return aviary.pigeon.tmux.Record[]
local function records(output)
  local result, position = {}, 1
  while position <= #output do
    local values
    values, position = read_fields(output, position, #fields)
    assert(values[2] ~= "" and values[3] ~= "", "current window is not a Pigeon Agent")
    result[#result + 1] = { session = values[2], pane = values[1], tool = values[3], cwd = values[4] }
    position = position + 1
  end
  return result
end

-- list-clients resolves window fields against each client's own current
-- session; match the exact client PTY and skip other editors' clients.
-- display-message -c selects where to display a message, not the format target,
-- so it cannot resolve a specific client's session.
function M.current(client)
  local output = tmux({ "list-clients", "-F", client_format })
  local position = 1
  while position <= #output do
    local values
    values, position = read_fields(output, position, #client_fields)
    position = position + 1
    if values[1] == client then
      assert(values[3] ~= "" and values[4] ~= "", "current tmux window is not a Pigeon Agent")
      return { session = values[3], pane = values[2], tool = values[4], cwd = values[5] }
    end
  end
  error("terminal client is not attached to a Pigeon Agent", 0)
end

function M.list()
  local output = tmux({ "list-windows", "-a", "-f", "#{!=:#{@pigeon_session},}", "-F", format })
  local result, seen = {}, {}
  for _, record in ipairs(records(output)) do
    if not seen[record.session] then
      seen[record.session], result[#result + 1] = true, record
    end
  end
  table.sort(result, function(a, b)
    return a.session < b.session
  end)
  return result
end

function M.create(tool, argv, cwd)
  local name = ("aviary-pigeon-%d-%x"):format(vim.fn.getpid(), vim.uv.hrtime())
  return transaction(function(txn)
    local args = {
      "new-session",
      "-d",
      "-s",
      name,
      "-n",
      argument(tool):gsub("#", "##"),
      "-c",
      argument(cwd):gsub("#", "##"),
      "-P",
      "-F",
      "#{pane_id}",
      "--",
      "env",
      "--",
    }
    local output = txn:acquire(function()
      return tmux(vim.list_extend(args, vim.tbl_map(argument, argv)))
    end, function()
      tmux({ "kill-session", "-t", "=" .. name })
    end)
    local pane = assert(vim.trim(output):match("^%%%d+$"), "invalid tmux creation result")
    for key, value in pairs({
      ["destroy-unattached"] = "off",
      ["detach-on-destroy"] = "on",
      status = "off",
      prefix = "None",
      prefix2 = "None",
    }) do
      tmux({ "set-option", "-t", "=" .. name .. ":", key, value })
    end
    for key, value in pairs({
      ["remain-on-exit"] = "off",
      ["pane-border-status"] = "off",
    }) do
      tmux({ "set-option", "-w", "-t", "=" .. name .. ":", key, value })
    end
    tmux({ "set-option", "-w", "-t", "=" .. name .. ":", "@pigeon_session", argument(name) })
    tmux({ "set-option", "-w", "-t", "=" .. name .. ":", "@pigeon_tool", argument(tool) })
    return { session = name, pane = pane, tool = tool, cwd = cwd }
  end)
end

function M.attach(session)
  assert(vim.env.TMUX, "run Neovim inside tmux")
  return { "env", "-u", "TMUX", "tmux", "attach-session", "-t", "=" .. session }
end

function M.retarget(client, session)
  tmux({ "switch-client", "-c", client, "-t", "=" .. session })
end

function M.paste(pane, text)
  tmux({ "load-buffer", "-b", buffer_name, "-" }, text)
  tmux({ "paste-buffer", "-p", "-r", "-d", "-t", pane, "-b", buffer_name })
end

return M
