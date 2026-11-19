--- Pigeon owns one Terminal per Neovim. The Terminal stores its current Agent
--- and the client attached to that Agent's session; sends read this field.
--- Entry creates a Terminal only when none exists and otherwise retargets the
--- existing client. Actions are synchronous except picker confirmation.
--- Cancellation preserves the Terminal; failures warn once, never replay.
local Backends = require("aviary.pigeon.backends")
local Config = require("aviary.pigeon.config")
local Notify = require("aviary.shared.notify")
local Resources = require("aviary.shared.resources")
local protect = require("aviary.shared.protect")
local transaction = require("aviary.shared.transaction")

---@class aviary.pigeon.PigeonState
---@field window? integer current Terminal window; nil while hidden
---@field window_group? integer listeners owned by the current window
---@field terminal? aviary.pigeon.Terminal

---@class aviary.pigeon.Terminal
---@field buffer integer
---@field job integer
---@field client string PTY device path used as the tmux client name
---@field agent aviary.pigeon.Agent current Agent; first initialized by create, then by retarget
--- Agent implements Choice, so its id is available for current-Choice marking.
---@field retarget fun(self: self, agent: aviary.pigeon.Agent) move this Terminal's client; failed changes preserve the previous Agent
---@field send fun(self: self, message: aviary.shared.Message) evaluate completely, then paste without focusing
---@field status fun(self: self): string display label for the current Agent
local Terminal = {}
Terminal.__index = Terminal

---@type aviary.pigeon.PigeonState
local state = {}

---@class aviary.pigeon
---@field pick fun() choose an existing Agent or create a tool, then show it
---@field show fun() show the current Agent; pick when no Terminal exists
---@field send fun(message: aviary.shared.Message) evaluate and paste into the current Agent without focusing; warn when no Terminal exists
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string? rebuild configuration without replacing the Terminal
---@field status fun() report the current Agent without inventory discovery
local M = {}

---@return vim.api.keyset.win_config
local function geometry()
  local opts = Config().view
  local function cells(value, available)
    return math.max(1, math.min(math.floor(value <= 1 and available * value or value), available - 2))
  end
  local width, height = cells(opts.width, vim.o.columns), cells(opts.height, vim.o.lines - vim.o.cmdheight)
  return {
    relative = "editor",
    style = "minimal",
    border = opts.border,
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
  }
end

--- Show bufnr in the Terminal window, creating it and its listeners when absent.
---@param bufnr integer
local function show(bufnr)
  local window = state.window
  if not window then
    local acquired = transaction(function(txn)
      local opened = txn:acquire(Resources.window(bufnr, true, geometry()))
      vim.wo[opened].winfixbuf = true
      local group = txn:acquire(Resources.augroup("aviary_pigeon"))
      vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(opened),
        once = true,
        callback = function()
          if state.window == opened then
            state.window = nil
          end
          if state.window_group == group then
            state.window_group = nil
            vim.api.nvim_del_augroup_by_id(group)
          end
        end,
      })
      vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        callback = function()
          if vim.api.nvim_get_current_win() == opened then
            vim.cmd.startinsert()
          end
        end,
      })
      return { window = opened, group = group }
    end)
    window = acquired.window
    state.window, state.window_group = window, acquired.group
  end
  vim.api.nvim_win_set_buf(window, bufnr)
  vim.api.nvim_set_current_win(window)
  vim.cmd.startinsert()
end

--- Select a Choice and pass it to on_choice; cancellation passes nil.
---@param on_choice fun(choice?: aviary.pigeon.Choice)
local function pick(on_choice)
  local choices = Backends.list()
  assert(#choices > 0, "no Pigeon Agents or supported tools available")

  local current = state.terminal and state.terminal.agent
  if current then
    for index, choice in ipairs(choices) do
      if choice:id() == current:id() then
        table.insert(choices, 1, table.remove(choices, index))
        break
      end
    end
  end

  -- vim.ui.select may invoke on_choice after this function returns.
  vim.ui.select(choices, {
    prompt = "Pigeon Agent: ",
    format_item = function(choice)
      return tostring(choice) .. (current and choice:id() == current:id() and " [current]" or "")
    end,
  }, protect(on_choice))
end

--- Acquire the buffer and attach job, install action keymaps, then register
--- TermClose and commit state. The window is created separately; nvim_buf_call
--- binds jobstart(term = true) to buffer without requiring a visible window.
--- TermClose is registered after all fallible acquisition, so a failed create
--- leaves no callback behind.
---@param agent aviary.pigeon.Agent
---@return aviary.pigeon.Terminal
function Terminal.create(agent)
  return transaction(function(txn)
    local buffer = txn:acquire(Resources.buffer(false, true))
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "aviary-pigeon"
    local job = vim.api.nvim_buf_call(buffer, function()
      return vim.fn.jobstart(agent:attach(), { term = true })
    end)
    assert(job > 0, "failed to start attach job")
    local client = assert(vim.api.nvim_get_chan_info(job).pty, "attach job has no client pty")
    local terminal = setmetatable({ buffer = buffer, job = job, client = client, agent = agent }, Terminal)
    local cfg = Config()
    for action, keys in pairs(cfg.keymaps) do
      local handler = cfg.actions[action]
      for _, lhs in ipairs(keys) do
        vim.keymap.set({ "n", "t" }, lhs, function()
          handler(terminal)
        end, {
          buffer = buffer,
          silent = true,
          desc = "Pigeon " .. action,
        })
      end
    end
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buffer,
      once = true,
      callback = function()
        -- close_buffer() reports status == -1; the external deletion owns the
        -- window/buffer. State is cleared first, and Entry guarantees at most
        -- one Terminal, so no instance-ownership check is needed. For normal
        -- exits, deleting the fixed buffer closes its window.
        local status = vim.v.event.status
        local current_group = state.window_group
        state.window, state.window_group, state.terminal = nil, nil, nil
        if current_group then
          vim.api.nvim_del_augroup_by_id(current_group)
        end
        if status == -1 then
          return
        end
        vim.api.nvim_buf_delete(buffer, { force = true })
      end,
    })
    state.terminal = terminal
    return terminal
  end)
end

---@param agent aviary.pigeon.Agent
function Terminal:retarget(agent)
  agent:retarget(self.client)
  self.agent = agent
end

---@param message aviary.shared.Message
function Terminal:send(message)
  local text = self.agent:eval(message)
  self.agent:send(text)
end

---@return string
function Terminal:status()
  return tostring(self.agent)
end

function M.pick()
  protect(function()
    pick(function(choice)
      if not choice then
        return
      end
      local agent = choice:resolve()
      local terminal = state.terminal
      if terminal then
        terminal:retarget(agent)
      else
        terminal = Terminal.create(agent)
      end
      show(terminal.buffer)
    end)
  end)()
end

function M.show()
  protect(function()
    local terminal = state.terminal
    if terminal then
      show(terminal.buffer)
    else
      -- M.show established that no Terminal exists, so create directly.
      pick(function(choice)
        if not choice then
          return
        end
        local created = Terminal.create(choice:resolve())
        show(created.buffer)
      end)
    end
  end)()
end

---@param message aviary.shared.Message
function M.send(message)
  protect(function()
    local terminal = assert(state.terminal, "Pigeon has no attached Agent; call pigeon.pick() or pigeon.show() first")
    terminal:send(message)
  end)()
end

---@param opts? aviary.pigeon.ConfigOverrides
---@return boolean
---@return string?
function M.setup(opts)
  return Config.setup(opts)
end

function M.status()
  protect(function()
    Notify.info("pigeon: agent: " .. (state.terminal and state.terminal:status() or "not attached"))
  end)()
end

return M
