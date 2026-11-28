--- Pigeon options and built-in actions.
--- Setup rebuilds from defaults, rejects unknown fields, and preserves current
--- options on failure; it acquires no resources. Actions receive a lazy
--- current-Agent getter and the captured reference. Resolvers receive the
--- resolved Agent and reference and return text.
---
--- Config() returns borrowed, read-only running options.
---@class aviary.pigeon.ConfigModule
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string?
---@operator call:aviary.pigeon.Config
local M = {}

---@alias aviary.pigeon.Format fun(path: string, start_row?: integer, end_row?: integer): string?
---@alias aviary.pigeon.AgentGetter fun(): aviary.pigeon.Agent resolve the current Agent; raises when the client is not attached to a Pigeon Agent
---@alias aviary.pigeon.Actions table<string, fun(current: aviary.pigeon.AgentGetter, reference: aviary.pigeon.Reference)>
---@alias aviary.pigeon.Keymaps table<string, string[]> action name to complete key set; empty disables
---@alias aviary.pigeon.Resolver fun(agent: aviary.pigeon.Agent, reference: aviary.pigeon.Reference): string

---@class aviary.pigeon.Tool
---@field command string[] nonempty argv with the program name first and no embedded NULs
---@field format aviary.pigeon.Format formatter resolved during setup

---@class aviary.pigeon.ViewConfig
---@field width number fraction of editor columns in (0, 1], or integer cells > 1
---@field height number fraction of editor lines in (0, 1], or integer cells > 1
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"

---@class aviary.pigeon.Config
---@field backend aviary.pigeon.BackendName
---@field tools table<string, aviary.pigeon.Tool>
---@field keymaps aviary.pigeon.Keymaps mappings installed in the Terminal buffer
---@field actions aviary.pigeon.Actions handlers called with a lazy current-Agent getter and captured reference
---@field prompts table<string, string> named prompt templates (name -> template)
---@field resolvers table<string, aviary.pigeon.Resolver> token handlers; resolver text is concatenated verbatim
---@field view aviary.pigeon.ViewConfig

---@class aviary.pigeon.ConfigOverrides
---@field backend? aviary.pigeon.BackendName
---@field tools? table<string, aviary.pigeon.ToolOverrides> built-ins may be partially overridden; custom tools require command
---@field keymaps? aviary.pigeon.Keymaps each action's key set replaces its defaults; {} disables it
---@field actions? aviary.pigeon.Actions built-in overrides and user-defined handlers
---@field prompts? table<string, string> add named templates or replace matching built-ins; unmatched built-ins remain
---@field resolvers? table<string, aviary.pigeon.Resolver> add handlers or override built-ins
---@field view? aviary.pigeon.ViewConfigOverrides

---@class aviary.pigeon.ToolOverrides
---@field command? string[]
---@field format? aviary.pigeon.Format

---@class aviary.pigeon.ViewConfigOverrides
---@field width? number
---@field height? number
---@field border? "none"|"single"|"double"|"rounded"|"solid"|"shadow"

local Schema = require("aviary.shared.schema")

---@type aviary.pigeon.Actions
local actions = {}

function actions.close()
  vim.api.nvim_win_close(0, true)
end

function actions.prompt(current, reference)
  local config = M()
  local names = vim.tbl_keys(config.prompts)
  if #names == 0 then
    require("aviary.shared.notify").warn("pigeon: no prompts are configured")
    return
  end
  local protect = require("aviary.shared.protect")
  protect(function()
    local agent = current()
    table.sort(names)
    local prompts, resolvers = config.prompts, config.resolvers
    vim.ui.select(names, { prompt = "Prompt: " }, function(name)
      -- Snacks returns focus before leaving Insert mode and calls on_choice afterward.
      vim.cmd.startinsert()
      if not name then
        return
      end
      local template = prompts[name]
      protect(function()
        local out = {}
        local from = 1
        for at, token, after in template:gmatch("(){([%w_]+)}()") do
          local resolve = resolvers[token]
          if resolve then
            out[#out + 1] = template:sub(from, at - 1)
            out[#out + 1] = resolve(agent, reference)
            from = after
          end
        end
        out[#out + 1] = template:sub(from)
        agent:send(table.concat(out))
      end)()
    end)
  end)()
end

function actions.pick(current)
  local protect = require("aviary.shared.protect")
  protect(function()
    local client = vim.api.nvim_get_chan_info(vim.b.terminal_job_id).pty
    local agent = current()
    local current_id = agent:id()
    local choices = require("aviary.pigeon.backends").list(agent)
    assert(#choices > 0, "no Pigeon Agents or supported tools available")
    vim.ui.select(
      choices,
      {
        prompt = "Pigeon Agent: ",
        format_item = function(choice)
          return tostring(choice) .. (choice:id() == current_id and " [current]" or "")
        end,
      },
      protect(function(choice)
        vim.cmd.startinsert()
        if not choice then
          return
        end
        choice:materialize():retarget(client)
      end)
    )
  end)()
end

function actions.buffers(current)
  local protect = require("aviary.shared.protect")
  protect(function()
    local names = {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buffer].buflisted and vim.bo[buffer].buftype == "" then
        local name = vim.api.nvim_buf_get_name(buffer)
        if name ~= "" then
          names[#names + 1] = name
        end
      end
    end
    if #names == 0 then
      require("aviary.shared.notify").warn("pigeon: no file buffers")
      return
    end
    table.sort(names)
    local agent = current()
    vim.ui.select(
      names,
      {
        prompt = "Buffer: ",
        format_item = function(name)
          return vim.fn.fnamemodify(name, ":~:.")
        end,
      },
      protect(function(name)
        -- Snacks returns focus before leaving Insert mode and calls on_choice afterward.
        vim.cmd.startinsert()
        if not name then
          return
        end
        agent:send(agent:eval({ path = name }))
      end)
    )
  end)()
end

-- stylua: ignore
local schema = Schema.object({
  backend = Schema.string({ default = "tmux" }),
  tools = Schema.object({
    [Schema.string()] = Schema.object({
      command = Schema.array("string", { min = 1 }),
      format = Schema.func({
        default = function(path, start_row, end_row)
          if not start_row then
            return path
          end
          local loc = (":L%d"):format(start_row)
          if end_row and end_row ~= start_row then
            loc = loc .. "-" .. end_row
          end
          return path .. " " .. loc
        end
      })
    })
  }, {
    default = {
      codex = { command = { "codex" } },
      claude = {
        command = { "claude" },
        format = function(path, start_row, end_row)
          local mention = path:find("[^%w/_%.%-]") and ('"' .. path .. '"') or path
          local loc = start_row and ("#L%d"):format(start_row) or ""
          if start_row and end_row and end_row ~= start_row then
            loc = loc .. "-" .. end_row
          end
          return "@" .. mention .. loc
        end
      }
    }
  }),
  keymaps = Schema.object({ [Schema.string()] = Schema.array("string") }, { default = { close = { "<C-.>" } } }),
  actions = Schema.object({ [Schema.string()] = Schema.func() }, { default = actions }),
  prompts = Schema.object({ [Schema.string()] = Schema.string() }, {
    default = {
      ["{file}"] = "{file} ",
      ["{line}"] = "{line} "
    }
  }),
  resolvers = Schema.object({ [Schema.string()] = Schema.func() }, {
    default = {
      file = function(agent, reference)
        return agent:eval({ path = reference.path })
      end,
      line = function(agent, reference)
        return agent:eval(reference)
      end
    }
  }),
  view = Schema.object({
    width = Schema.number(),
    height = Schema.number(),
    border = Schema.string()
  }, {
    default = { width = 0.9, height = 0.9, border = "rounded" }
  })
})

local options = assert(Schema.resolve(schema, {}, "pigeon"))

function M.setup(opts)
  local config, reason = Schema.resolve(schema, opts or {}, "pigeon")
  if config == nil then
    return false, reason
  end
  options = config
  return true, nil
end

return setmetatable(M, {
  __call = function()
    return options
  end,
})
