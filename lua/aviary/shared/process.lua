--- Synchronous command execution with one result model.
--- run() waits without interpreting exit codes or reporting errors to the user.
--- Commands are complete literal argument vectors without shell interpretation.
--- Arguments and options are borrowed without modification; output is captured.

--- Supported execution options; output is always captured in the returned Result.
---@class aviary.shared.process.RunOpts
---@field cwd? string working directory; nil inherits the editor's cwd
---@field env? table<string, string> overrides added to the inherited environment
---@field stdin? string input written to the command; nil supplies no input
---@field text? boolean normalize CRLF output to LF; defaults to true

---@class aviary.shared.process.Result
---@field code integer exit code, or -1 when the command could not start
---@field signal integer termination signal, or 0
---@field stdout string empty when the process produced no stdout
---@field stderr string startup error or captured stderr; empty when absent

---@class aviary.shared.process
---@field run fun(command: string[], opts?: aviary.shared.process.RunOpts): aviary.shared.process.Result
local M = {}

function M.run(command, opts)
  local options = vim.tbl_extend("force", { text = true }, opts or {})
  local ok, process = pcall(vim.system, command, options)
  if not ok then
    return { code = -1, signal = 0, stdout = "", stderr = tostring(process) }
  end
  local result = process:wait()
  return {
    code = result.code,
    signal = result.signal,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

return M
