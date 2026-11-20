--- Pigeon owns one Terminal per Neovim. The Terminal stores the client attached
--- to an Agent's session; the current Agent is resolved from that client when an
--- action uses it. Actions receive a lazy current-Agent getter and the reference
--- captured when show last focused the Terminal. Entry creates a Terminal only
--- when none exists. Actions are synchronous except picker/select confirmation.
--- Cancellation preserves the Terminal; failures warn once, never replay.
local Backends = require("aviary.pigeon.backends")
local Config = require("aviary.pigeon.config")
local Editor = require("aviary.shared.editor")
local Resources = require("aviary.shared.resources")
local protect = require("aviary.shared.protect")
local transaction = require("aviary.shared.transaction")

--- A captured editor location; plain data with a snapshotted path.
---@class aviary.pigeon.Reference
---@field path string captured absolute filename, or empty for an unnamed buffer
---@field start_row? integer captured first selected row or cursor row; nil for a whole-file reference
---@field end_row? integer captured last selected row; omitted for a single row

---@class aviary.pigeon.PigeonState
---@field window? integer current Terminal window; nil while hidden
---@field window_group? integer listeners owned by the current window
---@field terminal? aviary.pigeon.Terminal
---@field reference? aviary.pigeon.Reference latest captured editor context

---@class aviary.pigeon.Terminal
---@field buffer integer
---@field job integer
---@field client string PTY device path used as the tmux client name
local Terminal = {}
Terminal.__index = Terminal

---@type aviary.pigeon.PigeonState
local state = {}

---@class aviary.pigeon
---@field show fun() show the Terminal; pick when no Terminal exists
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string? rebuild configuration without replacing the Terminal
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
    local terminal = setmetatable({ buffer = buffer, job = job, client = client }, Terminal)
    ---@type aviary.pigeon.AgentGetter
    local current = function()
      return Backends.current(terminal.client)
    end
    local cfg = Config()
    for action, keys in pairs(cfg.keymaps) do
      local handler = cfg.actions[action]
      for _, lhs in ipairs(keys) do
        vim.keymap.set({ "n", "t" }, lhs, function()
          handler(current, state.reference)
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

function M.show()
  protect(function()
    local terminal = state.terminal
    local buf = vim.api.nvim_get_current_buf()
    -- Calls from the Terminal itself must not replace the captured reference.
    if terminal and buf == terminal.buffer then
      show(terminal.buffer)
      return
    end
    -- Capture the current editor location for Terminal actions. Visual mode
    -- captures inclusive whole lines and returns to Normal; other modes capture
    -- the cursor row.
    local path = vim.api.nvim_buf_get_name(buf)
    local first, last = Editor.selection()
    state.reference = {
      path = path,
      start_row = first,
      end_row = first ~= last and last or nil,
    }
    if terminal then
      show(terminal.buffer)
      return
    end
    -- M.show established that no Terminal exists, so create directly.
    local choices = Backends.list()
    assert(#choices > 0, "no Pigeon Agents or supported tools available")
    -- vim.ui.select may invoke the callback after this function returns.
    vim.ui.select(
      choices,
      { prompt = "Pigeon Agent: " },
      protect(function(choice)
        if not choice then
          return
        end
        local created = Terminal.create(choice:resolve())
        show(created.buffer)
      end)
    )
  end)()
end

---@param opts? aviary.pigeon.ConfigOverrides
---@return boolean
---@return string?
function M.setup(opts)
  return Config.setup(opts)
end

return M
