--- Health owns dependency diagnostics and read-only close-key conflict checks.
--- It never creates servers, bindings or receivers. Key checks reflect the current
--- editor's outer tmux context, not a guarantee about later runtime state.
--- An existing shared receiver binding supplies canonical key spelling;
--- otherwise raw-key conflicts can be reported but alias checks remain incomplete.
---@class aviary.pigeon.health
---@field check fun()
local M = {}

local Config = require("aviary.pigeon.config")
local Process = require("aviary.shared.process")

---@type fun()
local function check_close()
  local opts = Config().backend.tmux
  local source = Process.run({
    "tmux",
    "display-message",
    "-p",
    "-t",
    vim.env.TMUX_PANE,
    "#{session_attached}\t#{key-table}\t#{prefix}\t#{prefix2}",
  })
  if source.code ~= 0 then
    vim.health.warn("could not inspect outer tmux: " .. vim.trim(source.stderr))
    return
  end
  local attached, keys, prefix, prefix2 = source.stdout:match("^(%d+)\t([^\t]+)\t([^\t]+)\t([^\t\r\n]+)")
  if not attached or attached == "0" then
    vim.health.warn("tmux source session has no attached client")
    return
  end
  local normalized = Process.run({
    "tmux",
    "list-keys",
    "-T",
    "aviary-pigeon",
    "-F",
    "#{key_string}",
    Config.tmux_close_arg,
  })
  local canonical = normalized.code == 0 and vim.trim(normalized.stdout) or ""
  local close = canonical ~= "" and canonical or opts.close
  local bindings = Process.run({ "tmux", "list-keys", "-T", keys, "-F", "#{key_string}" })
  if bindings.code ~= 0 then
    vim.health.warn("could not inspect outer tmux bindings: " .. vim.trim(bindings.stderr))
    return
  end
  local consumed = close == prefix or close == prefix2
  for key in bindings.stdout:gmatch("[^\r\n]+") do
    consumed = consumed or key == close or key == "Any"
  end
  if consumed then
    vim.health.warn("tmux close key is used by the outer tmux; choose another backend.tmux.close key")
    return
  end
  if canonical == "" then
    vim.health.info("tmux close key: show a receiver before checking key aliases")
    return
  end
  vim.health.ok("tmux close key: no conflict in the current outer key table or prefixes")
end

function M.check()
  local config = Config()
  vim.health.start("aviary.pigeon")
  vim.health.ok("default backend: " .. config.backend.default)
  if vim.fn.has("clipboard") == 1 then
    vim.health.ok("clipboard: available")
  else
    local report = config.backend.default == "clipboard" and vim.health.error or vim.health.info
    report("clipboard: unavailable (no clipboard provider; see :checkhealth vim.provider)")
  end
  local reason
  if vim.fn.executable("tmux") ~= 1 then
    reason = "tmux executable is unavailable"
  else
    local result = Process.run({ "tmux", "-V" })
    local major, minor = result.stdout:match("(%d+)%.(%d+)")
    if result.code ~= 0 then
      reason = "could not read tmux version: " .. vim.trim(result.stderr)
    elseif not major then
      reason = "invalid tmux version"
    elseif tonumber(major) < 3 or (tonumber(major) == 3 and tonumber(minor) < 8) then
      reason = "tmux 3.8+ is required for floating tool views"
    end
  end
  if not reason then
    local missing = {}
    for _, name in ipairs({ "TMUX", "TMUX_PANE" }) do
      if not vim.env[name] then
        missing[#missing + 1] = name
      end
    end
    if #missing > 0 then
      reason = table.concat(missing, " and ") .. " not set; run Neovim inside tmux"
    end
  end
  if reason then
    local report = config.backend.default == "tmux" and vim.health.error or vim.health.info
    report("tmux: unavailable (" .. reason .. ")")
  else
    vim.health.ok("tmux: available")
    check_close()
  end
  for _, name in ipairs(vim.fn.sort(vim.tbl_keys(config.tools))) do
    local command = config.tools[name].command[1]
    local report = vim.fn.executable(command) == 1 and vim.health.ok or vim.health.info
    report(("tool %s: %s"):format(name, command))
  end
end

return M
