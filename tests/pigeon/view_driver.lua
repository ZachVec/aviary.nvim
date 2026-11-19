--- Real TUI fixture. Exercise public Pigeon actions and observe resources through
--- Neovim buffers, terminal channels and tmux clients; no production debug API.
---@diagnostic disable: duplicate-set-field
local repository = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
vim.opt.runtimepath:prepend(repository)
local Backend = require("aviary.pigeon.backends.tmux")
local Message = require("aviary.shared.message")
local Process = require("aviary.shared.process")
local M = { exits = {}, exit_count = 0, notes = {} }

vim.api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    M.exit_count = M.exit_count + 1
    M.exits[args.buf] = (M.exits[args.buf] or 0) + 1
  end,
})
vim.notify = function(text)
  M.notes[#M.notes + 1] = text
end
local Pigeon = require("aviary.pigeon")

local function terminal_buffers()
  return vim.tbl_filter(function(buffer)
    return vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "aviary-pigeon"
  end, vim.api.nvim_list_bufs())
end

---@return string?
local function client_session(client)
  local result = Process.run({ "tmux", "list-clients", "-F", "#{client_name}\t#{client_session}" }, { text = true })
  if result.code ~= 0 then
    return nil
  end
  for line in result.stdout:gmatch("[^\r\n]+") do
    local name, session = line:match("^([^\t]+)\t(.+)$")
    if name == client then
      return session
    end
  end
  return nil
end

local function snapshot()
  local buffer = terminal_buffers()[1]
  local job = buffer and vim.b[buffer].terminal_job_id or nil
  local client
  if job and job > 0 then
    local ok, info = pcall(vim.api.nvim_get_chan_info, job)
    client = ok and info.pty or nil
  end
  local session = client and client_session(client) or nil
  local agent
  if session then
    for _, choice in ipairs(Backend.list()) do
      if choice.session == session then
        ---@cast choice aviary.pigeon.tmux.Agent
        agent = { id = choice:id(), session = choice.session, pane = choice.pane, tool = choice.tool, cwd = choice.cwd }
        break
      end
    end
  end
  local windows = buffer and vim.fn.win_findbuf(buffer) or {}
  return {
    buffer = buffer,
    window = windows[1],
    job = job,
    client = client,
    session = session,
    agent = agent,
    exits = buffer and M.exits[buffer] or nil,
    exit_count = M.exit_count,
    buffers = terminal_buffers(),
    notes = M.notes,
    modified_enter_mapped = vim.fn.maparg("<S-CR>", "t") ~= "" or vim.fn.maparg("<M-CR>", "t") ~= "",
    mode = vim.api.nvim_get_mode().mode,
    current_window = vim.api.nvim_get_current_win(),
    text = buffer and vim.api.nvim_buf_get_lines(buffer, 0, -1, false) or nil,
    errors = vim.v.errmsg,
  }
end

function M.request(encoded)
  local request = vim.json.decode(encoded)
  local action = request.action
  if action == "list" then
    local result = {}
    for _, choice in ipairs(Backend.list()) do
      if choice.session then
        ---@cast choice aviary.pigeon.tmux.Agent
        result[#result + 1] = {
          id = choice:id(),
          session = choice.session,
          pane = choice.pane,
          tool = choice.tool,
          cwd = choice.cwd,
        }
      end
    end
    return result
  elseif action == "create" then
    assert(Pigeon.setup({ tools = { [request.tool] = { command = request.argv } } }))
    for _, choice in ipairs(Backend.list()) do
      if choice:id() == request.tool and not choice.session then
        local agent = choice:resolve()
        return {
          id = agent:id(),
          session = agent.session,
          pane = agent.pane,
          tool = agent.tool,
          cwd = agent.cwd,
        }
      end
    end
    error("missing creation choice")
  elseif action == "select" then
    local saved = vim.ui.select
    vim.ui.select = function(choices, _, done)
      for _, choice in ipairs(choices) do
        if choice:id() == request.target.id then
          done(choice)
          return
        end
      end
      error("missing Agent")
    end
    local ok, err = pcall(Pigeon.pick)
    vim.ui.select = saved
    assert(ok, err)
  elseif action == "show" then
    Pigeon.show()
  elseif action == "exit-client" then
    local buffer = assert(terminal_buffers()[1], "no Terminal")
    assert(vim.fn.jobstop(assert(vim.b[buffer].terminal_job_id)) == 1)
    return true
  elseif action == "delete-buffer" then
    local buffer = assert(terminal_buffers()[1], "no Terminal")
    vim.api.nvim_buf_delete(buffer, { force = true })
    return true
  elseif action == "send" or action == "reference" then
    Pigeon.send(
      action == "send" and Message.text(request.text) or Message.reference(request.path, request.first, request.last)
    )
    assert(#M.notes == 0, table.concat(M.notes, "\n"))
    return snapshot().session
  elseif action == "pick" then
    Pigeon.pick()
    return true
  elseif action ~= "snapshot" then
    error("unknown action: " .. action)
  end
  assert(#M.notes == 0, table.concat(M.notes, "\n"))
  return snapshot()
end

_G.PigeonTest = M
