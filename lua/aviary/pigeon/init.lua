--- Pigeon owns one current Target. Discovery and target actions are synchronous;
--- picker confirmation may happen later.
--- Backend/Target contracts: backends/init.lua. Collaboration: docs/pigeon/architecture.md.
--- A sole Choice resolves directly; multiple Choices use native selection.
--- Commit only complete resolved Targets. Resolution, evaluation, display and
--- delivery exceptions warn once, clear current and end the request. Discovery
--- failure warns and preserves current; cancellation is quiet and preserves it.
--- Current is a destination reference, not a guarantee of liveness. Actions never replay.
--- Messages remain borrowed unchanged until evaluation, including selection waits.
local Backends = require("aviary.pigeon.backends")
local Config = require("aviary.pigeon.config")
local Notify = require("aviary.shared.notify")
local protect = require("aviary.shared.protect")

---@class aviary.pigeon
---@field pick fun() select and display an existing destination or new tool
---@field show fun() display current; select only when current is empty
---@field send fun(message: aviary.shared.Message) deliver without changing focus; select only when current is empty
---@field setup fun(opts?: aviary.pigeon.ConfigOverrides): boolean, string? reset configuration without replacing current
---@field status fun() report current without discovery
local M = {}

---@type aviary.pigeon.Target?
local current

---@type fun(fn: fun(target: aviary.pigeon.Target))
local function pick(fn)
  local ok, choices = pcall(function()
    local name = Config().backend.default
    local choices = Backends.get(name).list()
    assert(#choices > 0, "no " .. name .. " targets or supported tools available")
    return choices
  end)
  if not ok then
    Notify.warn(tostring(choices))
    return
  end
  local resolve = protect(function(choice)
    current = choice:resolve()
    fn(current)
  end)
  local function choose(choice)
    if choice and not resolve(choice) then
      current = nil
    end
  end
  if #choices == 1 then
    choose(choices[1])
    return
  end
  if current then
    local label = tostring(current)
    for index, choice in ipairs(choices) do
      if tostring(choice) == label then
        table.insert(choices, 1, table.remove(choices, index))
        break
      end
    end
  end
  vim.ui.select(choices, {
    prompt = "Pigeon target: ",
    format_item = function(choice)
      local label = tostring(choice)
      return label .. (current and label == tostring(current) and " [current]" or "")
    end,
  }, choose)
end

---@type fun(fn: fun(target: aviary.pigeon.Target))
local function with_target(fn)
  if not current then
    pick(fn)
    return
  end
  if not protect(fn)(current) then
    current = nil
  end
end

function M.pick()
  pick(function(target)
    target:show()
  end)
end

function M.show()
  with_target(function(target)
    target:show()
  end)
end

function M.send(message)
  with_target(function(target)
    local text = target:eval(message)
    target:send(text)
  end)
end

function M.setup(opts)
  return Config.setup(opts)
end

function M.status()
  local label = current and tostring(current) or ("not chosen yet (default: %s)"):format(Config().backend.default)
  Notify.info("pigeon: target: " .. label)
end

return M
