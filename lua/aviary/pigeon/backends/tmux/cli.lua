--- Synchronous resource operations on Neovim's existing tmux server. TMUX and
--- TMUX_PANE are trusted host context; discovery queries succeed even when no
--- receivers or displays match. Command errors raise; only best-effort acquisition
--- cleanup catches failures. The host permits detached session creation;
--- operations perform no environment or version diagnostics.
--- Receivers carry @pigeon_tool; it supplies tool identity while
--- native session names and pane_start_path supply instance and launch directory.
--- Focus discovers/reuses the source's marked float or creates one. View
--- acquisition/configuration failure attempts to close the acquired pane,
--- including reused displays. Receiver key-table changes are outside that rollback
--- scope; an invalid close key preserves the previous binding. Sending leaves the
--- display alone.
--- Focus launches the attach client without waiting for readiness.
local Config = require("aviary.pigeon.config")
local Process = require("aviary.shared.process")
local transaction = require("aviary.shared.transaction")

---@class aviary.pigeon.tmux.cli
---@field list fun(): {name: string, tool: string, cwd: string}[] only marked receivers
---@field create fun(name: string, window: string, argv: string[], cwd: string, options: table<string, string>) acquire/configure transactionally
---@field focus fun(session: string) discover/reuse the source's display or create one; roll back the acquired pane on failure
---@field paste fun(address: string, text: string) load then paste; failures raise without changing the display
local M = {}
-- Synchronous load/paste pairs keep reuse of this per-editor buffer from interleaving.
local buffer_name = "aviary-pigeon-" .. vim.fn.getpid()

---@type fun(args: string[], stdin?: string): string
local function tmux(args, stdin)
  local argv = { "tmux" }
  vim.list_extend(argv, args)
  local result = Process.run(argv, { stdin = stdin, text = false })
  assert(result.code == 0, result.stderr)
  return result.stdout
end

---@type fun(value: string): string
local function argument(value)
  return (value:gsub(";$", "\\;"))
end

function M.list()
  -- Length-prefixed fields preserve embedded separators.
  local format =
    "#{n:session_name}:#{session_name}#{n:@pigeon_tool}:#{@pigeon_tool}#{n:pane_start_path}:#{pane_start_path}"
  local output = tmux({ "list-sessions", "-f", "#{!=:#{@pigeon_tool},}", "-F", format })
  local sessions, position = {}, 1
  while position <= #output do
    local fields = {}
    for index = 1, 3 do
      local colon = output:find(":", position, true)
      local last = colon + tonumber(output:sub(position, colon - 1))
      fields[index] = output:sub(colon + 1, last)
      position = last + 1
    end
    sessions[#sessions + 1] = { name = fields[1], tool = fields[2], cwd = fields[3] }
    position = position + 1
  end
  return sessions
end

function M.create(name, window, argv, cwd, options)
  transaction(function(txn)
    txn:acquire(function()
      local directory = argument(cwd):gsub("#", "##")
      local window_name = argument(window):gsub("#", "##")
      local args = { "new-session", "-d", "-s", name, "-n", window_name, "-c", directory, "--", "env", "--" }
      tmux(vim.list_extend(args, vim.iter(argv):map(argument):totable()))
      return name
    end, function(session)
      pcall(tmux, { "kill-session", "-t", "=" .. session })
    end)
    tmux({ "set-option", "-w", "-t", "=" .. name .. ":", "remain-on-exit", "off" })
    for key, value in pairs(options) do
      tmux({ "set-option", "-t", "=" .. name .. ":", key, argument(value) })
    end
    return nil
  end)
end

function M.focus(session)
  local opts = Config().backend.tmux
  local origin = vim.env.TMUX_PANE
  local socket = vim.env.TMUX:match("^(.*),%d+,%d+$")
  -- Bind before clearing so an invalid key cannot remove the previous binding.
  tmux({ "bind-key", "-T", "aviary-pigeon", Config.tmux_close_arg, "detach-client" })
  tmux({ "unbind-key", "-a", "-T", "aviary-pigeon" })
  tmux({ "bind-key", "-T", "aviary-pigeon", Config.tmux_close_arg, "detach-client" })
  tmux({ "set-option", "-t", "=" .. session .. ":", "key-table", "aviary-pigeon" })
  transaction(function(txn)
    local pane = txn:acquire(function()
      local filter = "#{&&:#{pane_floating_flag},#{==:#{@pigeon_source}," .. origin .. "}}"
      local existing = vim.trim(tmux({ "list-panes", "-t", origin, "-f", filter, "-F", "#{pane_id}" }))
      if existing ~= "" then
        return existing
      end
      return vim.trim(tmux({ "new-pane", "-d", "-E", "-A", "-t", origin, "-P", "-F", "#{pane_id}" }))
    end, function(pane)
      pcall(tmux, { "kill-pane", "-t", pane })
    end)
    tmux({ "set-option", "-p", "-t", pane, "@pigeon_source", origin })
    tmux({ "set-option", "-p", "-t", pane, "remain-on-exit", "off" })
    local on_exit = ("if-shell -F '#{pane_active}' 'select-pane -Z -t %s'"):format(origin)
    tmux({ "set-hook", "-p", "-t", pane, "pane-exited", on_exit })
    tmux({ "resize-pane", "-t", pane, "-x", opts.width, "-y", opts.height })
    tmux({ "move-pane", "-t", pane, "-P", "centre" })
    tmux({ "move-pane", "-t", pane, "-P", "front" })
    local attach = { "tmux", "-S", socket, "attach-session", "-t", "=" .. session }
    tmux({ "respawn-pane", "-k", "-t", pane, "--", "env", "-u", "TMUX", unpack(attach) })
    tmux({ "select-pane", "-Z", "-t", pane })
    return nil
  end)
end

function M.paste(address, text)
  tmux({ "load-buffer", "-b", buffer_name, "-" }, text)
  tmux({ "paste-buffer", "-p", "-d", "-t", address, "-b", buffer_name })
end

return M
